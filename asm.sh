#!/bin/sh
output=$(zig build audio --verbose 2>&1 | head -n 1 | sed 's/--listen=-/-femit-asm/')
$output

