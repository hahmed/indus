#!/bin/bash
# disassemble indus output: tools/dis.sh file.rb
MC=/nix/store/12dd5mabslv1wsc09gdgikii91qarzca-llvm-19.1.7/bin/llvm-mc
HEX=1 "$(dirname "$0")/../bin/indus" "$1" | awk '{w=$2; printf "0x%s 0x%s 0x%s 0x%s\n", substr(w,7,2), substr(w,5,2), substr(w,3,2), substr(w,1,2)}' \
  | $MC --disassemble --triple=aarch64 2>/dev/null | grep -v '^\s*\.' | awk '{printf "%4d: %s\n", (NR-1)*4, $0}'
