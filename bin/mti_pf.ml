let () = Printexc.record_backtrace true
let reporter = Logs_fmt.reporter ()
let () = Fmt.set_utf_8 Fmt.stdout true
let () = Fmt.set_utf_8 Fmt.stderr true
let () = Fmt.set_style_renderer Fmt.stdout `Ansi_tty
let () = Fmt.set_style_renderer Fmt.stderr `Ansi_tty
let () = Logs.set_level ~all:true (Some Logs.Debug)
let () = Logs.set_reporter reporter

let ( <.> ) f g = fun x -> f (g x)
let apply x f = f x

open Rresult
open Lwt.Infix

module Make
    (Random : Mirage_random.S)
    (Mclock : Mirage_clock.MCLOCK)
    (Pclock : Mirage_clock.PCLOCK)
    (StackV4 : Mirage_stack.V4)
= struct
  module TCP = Tuyau_mirage_tcp.Make(StackV4)
  module DNS = Dns_client_mirage.Make(Random)(Mclock)(StackV4)

  open Lwt_backend

  let src = Logs.Src.create "MTI-PF"
  module Log = ((val Logs.src_log src) : Logs.LOG)

  module type FLOW = Ptt.Sigs.FLOW with type +'a s = 'a Lwt.t
  let failwithf fmt = Fmt.kstrf (fun err -> Failure err) fmt

  let flow
    : type flow. (module Tuyau_mirage.FLOW with type flow = flow) -> (module FLOW with type t = flow)
    = fun (module Flow) ->
    let ic_raw = Cstruct.create 0x1000 in
    let oc_raw = Cstruct.create 0x1000 in

    let recv flow buf off len =
      let len = min len (Cstruct.len ic_raw) in
      let ic_raw = Cstruct.sub ic_raw 0 len in
      let rec fiber = function
        | Ok `End_of_input -> Lwt.return 0
        | Ok (`Input 0) -> Flow.recv flow ic_raw >>= fiber
        | Ok (`Input len) ->
          Cstruct.blit_to_bytes ic_raw 0 buf off len ;
          Lwt.return len
        | Error err -> Lwt.fail (failwithf "%a" Flow.pp_error err) in
      Flow.recv flow ic_raw >>= fiber in

    let rec send flow buf off len =
      let n = min len (Cstruct.len oc_raw) in
      Cstruct.blit_from_string buf off oc_raw 0 n ;
      Flow.send flow (Cstruct.sub oc_raw 0 n) >>= function
      | Ok n ->
        if n = len then Lwt.return () else send flow buf (off + n) (len - n)
      | Error err -> Lwt.fail (failwithf "%a" Flow.pp_error err) in
    let module Flow = struct type t = flow type +'a s = 'a Lwt.t let recv = recv let send = send end in
    (module Flow)

  let rdwr
    : type flow. (module Tuyau_mirage.FLOW with type flow = flow) -> (flow, Lwt_scheduler.t) Colombe.Sigs.rdwr
    = fun (module Flow) ->
    let ic_raw = Cstruct.create 0x1000 in
    let oc_raw = Cstruct.create 0x1000 in

    let recv flow buf off len =
      let len = min len (Cstruct.len ic_raw) in
      let ic_raw = Cstruct.sub ic_raw 0 len in
      let rec fiber = function
        | Ok `End_of_input -> Lwt.return 0
        | Ok (`Input 0) -> Flow.recv flow ic_raw >>= fiber
        | Ok (`Input len) ->
          Cstruct.blit_to_bytes ic_raw 0 buf off len ;
          Lwt.return len
        | Error err -> Lwt.fail (failwithf "%a" Flow.pp_error err) in
      Flow.recv flow ic_raw >>= fiber in

    let rec send flow buf off len =
      let n = min len (Cstruct.len oc_raw) in
      Cstruct.blit_from_string buf off oc_raw 0 n ;
      Flow.send flow (Cstruct.sub oc_raw 0 n) >>= function
      | Ok n ->
        if n = len then Lwt.return () else send flow buf (off + n) (len - n)
      | Error err -> Lwt.fail (failwithf "%a" Flow.pp_error err) in

    let rd flow buf off len = Lwt_scheduler.inj (recv flow buf off len) in
    let wr flow buf off len = Lwt_scheduler.inj (send flow buf off len) in

    { Colombe.Sigs.rd; Colombe.Sigs.wr; }

  module Flow = (val (flow (Tuyau_mirage.impl_of_flow TCP.protocol)))

  module Resolver = struct
    type t = DNS.t
    type +'a s = 'a Lwt.t

    let gethostbyname w v = DNS.gethostbyname w v

    let getmxbyname w v = DNS.getaddrinfo w Dns.Rr_map.Mx v >>= function
      | Ok (_, v) -> Lwt.return (Ok v)
      | Error _ as err -> Lwt.return err

    let extension _w _ldh _v =
      Lwt.return (Rresult.R.error_msgf "Impossible to resolve [%s:%s]" _ldh _v)
  end

  module Random = struct
    type g = Random.g
    type +'a s = 'a Lwt.t

    let generate ?g buf =
      let len = Bytes.length buf in
      let raw = Random.generate ?g len in
      Cstruct.blit_to_bytes raw 0 buf 0 len ;
      Lwt.return ()
  end

  module Relay = Ptt.Relay.Make(Lwt_scheduler)(Lwt_io)(Flow)(Resolver)(Random)

  let ( >>? ) x f = x >>= function
    | Ok x -> f x
    | Error err -> Lwt.return (Error err)

  let ( >|? ) x f = x >>= function
    | Ok x -> Lwt.return (f x)
    | Error err -> Lwt.return (Error err)

  let plug_consumer_to_producers consumer producers =
    let rec go () = consumer () >>= function
      | Some v -> List.iter (fun producer -> producer (Some v)) producers ; Lwt.pause () >>= go
      | None -> List.iter (fun producer -> producer None) producers ; Lwt.return () in
    go

  let sendmail stack conf_server mx_ipaddr emitter producer recipients =
    let endpoint =
      { Tuyau_mirage_tcp.stack= stack
      ; Tuyau_mirage_tcp.keepalive= None
      ; Tuyau_mirage_tcp.ip= mx_ipaddr
      ; Tuyau_mirage_tcp.port= 25 } in
    Tuyau_mirage.flow_of_protocol ~key:TCP.endpoint endpoint ~protocol:TCP.protocol >>? fun flow ->
    let ctx = Sendmail_with_tls.Context_with_tls.make () in
    let rdwr = rdwr (Tuyau_mirage.impl_of_flow TCP.protocol) in
    let tls = Tls.Config.client ~authenticator:X509.Authenticator.null () in
    let domain =
      let vs = Domain_name.to_strings (Relay.info conf_server).Ptt.SMTP.domain in
      Colombe.Domain.Domain vs in
    Lwt.catch
      (fun () ->
         Sendmail_with_tls.sendmail lwt rdwr flow ctx tls ~domain emitter recipients producer
         |> Lwt_scheduler.prj >|= R.reword_error (fun err -> `Sendmail err))
      (function Failure err -> Lwt.return (R.error_msg err) (* XXX(dinosaure): should come from [rdwr]. *)
              | exn -> Lwt.return (Error (`Exn exn))) >>= function
    | Ok () -> Lwt.return (Ok ())
    | Error (`Sendmail err) ->
      Lwt.return (R.error_msgf "%a" Sendmail_with_tls.pp_error err)
    | Error (`Msg _) as err ->
      Lwt.return err
    | Error (`Exn exn) ->
      Log.err (fun m -> m "Got an exception: %s" (Printexc.to_string exn)) ;
      Lwt.return (Error (`Msg "Unknown exception"))

  let ( <+> ) s0 s1 =
    let current = ref s0 in
    let rec next () =
      let tmp = Lwt_scheduler.prj (!current ()) in
      let res = tmp >>= function
        | Some _ -> tmp
        | None ->
          if !current == s1
          then Lwt.return None
          else ( current := s1 ; Lwt_scheduler.prj (next ()) ) in
      Lwt_scheduler.inj res in
    next

  let transmit stack resolver conf_server relay_map (key, queue, consumer) =
    Relay.resolve_recipients ~domain:(Relay.info conf_server).domain resolver relay_map
      (List.map fst (Ptt.Messaged.recipients key)) >>= fun resolved ->
    let producers, targets =
      List.fold_left (fun (producers, targets) target ->
          let stream, producer = Lwt_stream.create () in
          let stream () = Lwt_scheduler.inj (Lwt_stream.get stream) in
          (producer :: producers), (stream, target) :: targets)
        ([], []) resolved in
    let emitter, _ = Ptt.Messaged.from key and id = Ptt.Messaged.id key in
    let received recipient =
      let by = Domain_name.to_strings (Relay.info conf_server).domain in
      let id =
        let open Mrmime.Mailbox in
        Local.(v [ w (Fmt.strf "%08LX" id) ]), `Domain by in
      let received = Received.make
        ~from:(Received.Only (Ptt.Messaged.domain_from key))
        ~by:(Received.Only (Colombe.Domain.Domain by))
        ~via:Received.tcp
        ~protocol:Received.esmtp
        ~id ~zone:(Relay.info conf_server).Ptt.SMTP.zone recipient (Ptime.v (Pclock.now_d_ps ())) in
      let stream = Prettym.to_stream Received.Encoder.as_field received in
      let stream = Lwt_stream.from (Lwt.return <.> stream) |> Lwt_stream.map (fun s -> s, 0, String.length s) in
      (Lwt_scheduler.inj <.> (fun () -> Lwt_stream.get stream)) in
    let transmit = plug_consumer_to_producers consumer producers in
    let sendmails =
      let sendmail (stream, (k, vs)) () =
        let open Colombe in
        let open Forward_path in
        let mx_domain, mxs = match k with
          | `Ipaddr ((Ipaddr.V4 v4) as mx_ipaddr) -> Domain.IPv4 v4, Ptt.Mxs.(singleton (v ~preference:0 mx_ipaddr))
          | `Ipaddr ((Ipaddr.V6 v6) as mx_ipaddr) -> Domain.IPv6 v6, Ptt.Mxs.(singleton (v ~preference:0 mx_ipaddr))
          | `Domain (mx_domain, mxs) -> Domain.Domain (Domain_name.to_strings mx_domain), mxs in
        let recipients = match vs with
          | `All -> [ Domain mx_domain ]
          | `Local vs ->
            List.map (fun local ->
                let local = `Dot_string (List.map (function `Atom x -> x | `String x -> x) local) in
                Forward_path { Path.local= local; Path.domain= mx_domain; Path.rest= []; }) vs in
        let received = match recipients with
          | [ Forward_path path ] -> received (Some path)
          | _ -> received None in
        let stream = received <+> stream in
        let rec go = function
          | [] -> Lwt.return ()
          | { Ptt.Mxs.mx_ipaddr= Ipaddr.V6 _; _ } :: rest -> go rest
          | { Ptt.Mxs.mx_ipaddr= Ipaddr.V4 mx_ipaddr; _ } :: rest ->
            sendmail stack conf_server mx_ipaddr emitter stream recipients >>= function
            | Ok () -> Lwt.return ()
            | Error _ -> go rest in
        let sort = List.sort (fun { Ptt.Mxs.preference= a; _ } { Ptt.Mxs.preference= b; _ } -> Int.compare a b) in
        let sorted = Ptt.Mxs.elements mxs |> sort in
        go sorted in
      List.map sendmail targets in
    Lwt.join (List.map (apply ()) (transmit :: sendmails)) >>= fun () ->
    Relay.Md.close queue

  let smtp_relay_service resolver conf conf_server =
    Tuyau_mirage.impl_of_service ~key:TCP.configuration TCP.service |> Lwt.return >>? fun (module Server) ->
    Tuyau_mirage.serve ~key:TCP.configuration conf ~service:TCP.service >>? fun (t, protocol) ->
    let module Flow = (val (Tuyau_mirage.impl_of_flow protocol)) in
    let handle ip port flow () =
      Lwt.catch
        (fun () -> Relay.accept flow resolver conf_server
          >|= R.reword_error (R.msgf "%a" Relay.pp_error) >>= fun res ->
          Flow.close flow >>= function
          | Error err -> Lwt.return (R.error_msgf "%a" Flow.pp_error err)
          | Ok () -> Lwt.return res)
        (function Failure err -> Lwt.return (R.error_msg err)
                | exn -> Lwt.return (Error (`Exn exn))) >>= function
      | Ok () ->
        Log.info (fun m -> m "<%a:%d> submitted a message" Ipaddr.V4.pp ip port) ;
        Lwt.return ()
      | Error (`Msg err) ->
        Log.err (fun m -> m "<%a:%d> %s" Ipaddr.V4.pp ip port err) ;
        Lwt.return ()
      | Error (`Exn exn) ->
        Log.err (fun m -> m "<%a:%d> raised an unknown exception: %s" Ipaddr.V4.pp ip port (Printexc.to_string exn)) ;
        Lwt.return () in
    let rec go () =
      Server.accept t >>? fun flow ->
      let ip, port = TCP.dst flow in
      Lwt.async (handle ip port flow) ; Lwt.pause () >>= go in
    go () >|= R.reword_error (R.msgf "%a" Server.pp_error)

  let smtp_relay_service resolver conf conf_server =
    smtp_relay_service resolver conf conf_server >>= function
    | Ok () -> Lwt.return ()
    | Error err ->
      Log.err (fun m -> m "%a" Tuyau_mirage.pp_error err) ;
      Lwt.return ()

  let smtp_logic stack resolver conf_server messaged map =
    let rec go () =
      Relay.Md.await messaged >>= fun () ->
      Relay.Md.pop messaged >>= function
      | None -> Lwt.pause () >>= go
      | Some v -> Lwt.async (fun () -> transmit stack resolver conf_server map v) ; Lwt.pause () >>= go in
    go ()

  let fiber stack resolver conf map info =
    let conf_server = Relay.create ~info in
    let messaged = Relay.messaged conf_server in
    Lwt.join [ smtp_relay_service resolver conf conf_server
             ; smtp_logic stack resolver conf_server messaged map
             ; Nocrypto_entropy_lwt.initialize () ]
end

module Random = struct
  type g = unit

  let generate ?g:_ len =
    let ic = open_in "/dev/urandom" in
    let rs = Bytes.create len in
    really_input ic rs 0 len ; close_in ic ;
    Cstruct.of_bytes rs
end

module Server = Make(Random)(Mclock)(Pclock)(Tcpip_stack_socket)

let load_file filename =
  let open Rresult in
  Bos.OS.File.read filename >>= fun contents ->
  R.ok (Cstruct.of_string contents)

let cert =
  let open Rresult in
  load_file (Fpath.v "ptt.pem") >>= fun raw ->
  X509.Certificate.decode_pem raw

let cert = Rresult.R.get_ok cert

let private_key =
  let open Rresult in
  load_file (Fpath.v "ptt.key") >>= fun raw ->
  X509.Private_key.decode_pem raw >>= fun (`RSA v) -> R.ok v

let private_key = Rresult.R.get_ok private_key

let fiber ~domain map =
  Tcpip_stack_socket.TCPV4.connect None >>= fun tcpv4 ->
  Tcpip_stack_socket.UDPV4.connect None >>= fun udpv4 ->
  Tcpip_stack_socket.connect [] udpv4 tcpv4 >>= fun stackv4 ->
  let conf =
    { Tuyau_mirage_tcp.stack= stackv4
    ; Tuyau_mirage_tcp.keepalive= None
    ; Tuyau_mirage_tcp.port= 4242 } in
  let info =
    { Ptt.SMTP.domain
    ; Ptt.SMTP.ipv4= Ipaddr.V4.any
    ; Ptt.SMTP.tls= Tls.Config.server ~certificates:(`Single ([ cert ], private_key)) ~authenticator:X509.Authenticator.null ()
    ; Ptt.SMTP.zone= Mrmime.Date.Zone.GMT
    ; Ptt.SMTP.size= 0x1000000L } in
  let resolver = Server.DNS.create stackv4 in
  Server.fiber stackv4 resolver conf map info

let romain_calascibetta =
  let open Mrmime.Mailbox in
  Local.[ w "romain"; w "calascibetta" ] @ Domain.(domain, [ a "gmail"; a "com" ])

let () =
  let domain = Domain_name.(host_exn <.> of_string_exn) "x25519.net" in
  let map = Ptt.Relay_map.empty ~postmaster:romain_calascibetta ~domain in
  let map =
    let open Mrmime.Mailbox in
    Ptt.Relay_map.add
      ~local:(Local.(v [ w "romain"; w "calascibetta" ]))
      romain_calascibetta map in
  Lwt_main.run (fiber ~domain map)
