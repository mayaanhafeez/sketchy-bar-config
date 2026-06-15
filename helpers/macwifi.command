#!/bin/bash
echo -ne "\033]0;macwifi\007"
/usr/local/bin/macwifi
killall Terminal 2>/dev/null
