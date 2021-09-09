#!/bin/bash

albatross-client-local create submission submission.hvt \
	--net=service:br1 \
	--block=certificate:certificate-sub \
	--arg="--ipv4=192.168.1.4/24" \
	--arg="--ipv4-gateway=192.168.1.2" \
	--arg="--remote git@192.168.1.2:smtp.git" \
	--arg="--ssh-seed Wg1CrQ4eb4UB4K4uN1avrUQMstI41drvmxBg1NhG" \
	--arg="--destination 192.168.1.5" \
	--arg="--domain osau.re" \
	--arg="--postmaster hostmaster@osau.re" \
	--arg="--cert-fingerprint osau.re:SHA256:xD70Gj2fkgkyJZFA9RywcWGnH2e/d/eiP/fSlanCe3Y=" \
	--arg="-l debug"