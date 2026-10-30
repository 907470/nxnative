#!/usr/bin/env bash

# Configuration
STORAGE_DIR="${HOME}/switch-storage"
PORT=8080

# Ensure storage directory exists
mkdir -p "$STORAGE_DIR"

echo "=========================================================="
echo " Starting Local Switch File Server & Cloudflare Tunnel"
echo " Serving files from: $STORAGE_DIR"
echo "=========================================================="

# 1. Start Python HTTP Server in the background
python3 -m http.server "$PORT" --directory "$STORAGE_DIR" >/dev/null 2>&1 &
PYTHON_PID=$!

# Ensure Python server stops if the script exits
cleanup() {
    echo -e "\n[*] Shutting down local file server..."
    kill "$PYTHON_PID" 2>/dev/null
    exit 0
}
trap cleanup INT TERM

echo "[*] Python file server started (PID: $PYTHON_PID)"
echo "[*] Launching Cloudflare tunnel and waiting for URL..."

# 2. Run cloudflared and capture its output to a temporary log
LOG_FILE=$(mktemp)
cloudflared tunnel --url "http://localhost:$PORT" > "$LOG_FILE" 2>&1 &
CLOUDFLARE_PID=$!

cleanup_all() {
    kill "$PYTHON_PID" "$CLOUDFLARE_PID" 2>/dev/null
    rm -f "$LOG_FILE"
    exit 0
}
trap cleanup_all INT TERM

# 3. Loop to grab the trycloudflare URL from the log output
TUNNEL_URL=""
while [ -z "$TUNNEL_URL" ]; do
    sleep 1
    TUNNEL_URL=$(grep -oE "https://[a-zA-Z0-9.-]+\.trycloudflare\.com" "$LOG_FILE" | head -n 1)
done

echo "----------------------------------------------------------"
echo " FOUND URL: $TUNNEL_URL"
echo "----------------------------------------------------------"

# 4. Copy to clipboard & pop up a graphical dialog window
if command -v wl-copy &>/dev/null; then
    echo "$TUNNEL_URL" | wl-copy
elif command -v xclip &>/dev/null; then
    echo "$TUNNEL_URL" | xclip -selection clipboard
fi

# Open a dialog box based on available desktop utilities
if command -v kdialog &>/dev/null; then
    kdialog --textbox <(echo "Your Cloudflare Tunnel URL is:\n\n$TUNNEL_URL\n\n(It has been copied to your clipboard)") 400 200 --title "Switch File Server Active"
elif command -v zenity &>/dev/null; then
    zenity --info --title="Switch File Server Active" --text="Your Cloudflare Tunnel URL:\n\n$TUNNEL_URL\n\n(It has been copied to your clipboard)" --width=400
else
    echo "URL is ready: $TUNNEL_URL"
fi

# Wait for the cloudflared process to keep the tunnel alive until you close it
wait "$CLOUDFLARE_PID"
