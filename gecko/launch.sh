# lem's server frontend in a firefox window; the flake fills in the paths
data="${XDG_DATA_HOME:-$HOME/.local/share}/lem-gecko"
profile="$data/profile"
mkdir -p "$profile/chrome"
cp -f @userjs@ "$profile/user.js"
cp -f @userchrome@ "$profile/chrome/userChrome.css"
chmod u+w "$profile/user.js" "$profile/chrome/userChrome.css"

port="${LEM_GECKO_PORT:-}"
if [ -z "$port" ]; then
  for _ in $(seq 50); do
    port=$((20000 + RANDOM % 40000))
    nc -z 127.0.0.1 "$port" 2>/dev/null || break
  done
fi

LEM_GECKO=1 @server@ --port "$port" "$@" &
server=$!
for _ in $(seq 600); do
  nc -z 127.0.0.1 "$port" 2>/dev/null && break
  kill -0 "$server" 2>/dev/null || exit 1
  sleep 0.1
done

@browser@ --profile "$profile" --no-remote --new-instance "http://127.0.0.1:$port/" &
browser=$!
trap 'kill "$server" "$browser" 2>/dev/null' EXIT INT TERM
# stop both when either exits. firefox on macos keeps running after its last window closes, so
# the page staying disconnected for 3s (longer than a reload) counts as an exit too
connected=0
gone=0
while kill -0 "$server" 2>/dev/null && kill -0 "$browser" 2>/dev/null; do
  if lsof -nP -iTCP:"$port" -sTCP:ESTABLISHED >/dev/null 2>&1; then
    connected=1
    gone=0
  elif [ "$connected" = 1 ]; then
    gone=$((gone + 1))
    [ "$gone" -ge 6 ] && break
  fi
  sleep 0.5
done
