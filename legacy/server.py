import os
import pty
import asyncio
import fcntl
import struct
import termios
import signal
import json
import secrets
import socket
from aiohttp import web

import subprocess
import shutil

# Server-side state storage (persists across browser sessions)
STATE_FILE = os.path.expanduser('~/.rdock_state.json')
HTPASSWD_FILE = '/etc/nginx/.htpasswd'
SESSIONS = {}  # In-memory session store

# Base path for when rdock is served under a sub-path (e.g., /rdock)
# This affects redirects and asset paths
BASE_PATH = os.environ.get('RDOCK_BASE_PATH', '').rstrip('/')

def get_server_info():
    """Get server hostname and other info for display."""
    hostname = socket.gethostname()
    try:
        # Try to get FQDN
        fqdn = socket.getfqdn()
        if fqdn and fqdn != hostname:
            hostname = fqdn
    except:
        pass
    return {
        'hostname': hostname,
        'user': os.environ.get('USER', 'unknown'),
    }

def verify_htpasswd(username, password):
    """Verify username/password against nginx htpasswd file."""
    if not os.path.exists(HTPASSWD_FILE):
        print(f"Warning: htpasswd file not found at {HTPASSWD_FILE}")
        return False
    
    try:
        # Use htpasswd -vb to verify password (works with all hash formats)
        result = subprocess.run(
            ['htpasswd', '-vb', HTPASSWD_FILE, username, password],
            capture_output=True
        )
        return result.returncode == 0
    except Exception as e:
        print(f"Error verifying password: {e}")
    return False

def htpasswd_exists():
    """Check if htpasswd file exists and has users."""
    if not os.path.exists(HTPASSWD_FILE):
        return False
    try:
        with open(HTPASSWD_FILE, 'r') as f:
            return any(line.strip() for line in f)
    except:
        return False

def verify_session(request):
    """Check if request has valid session."""
    session_id = request.cookies.get('session_id')
    if session_id and session_id in SESSIONS:
        return True
    return False

def create_session(username):
    """Create a new session."""
    session_id = secrets.token_urlsafe(32)
    SESSIONS[session_id] = {'username': username}
    return session_id


def load_server_state():
    """Load persisted state from file."""
    try:
        if os.path.exists(STATE_FILE):
            with open(STATE_FILE, 'r') as f:
                return json.load(f)
    except Exception as e:
        print(f"Error loading state: {e}")
    return {'tabs': [], 'activeTabId': None, 'tabCounter': 0, 'terminalCounter': 0, 'vscodeCounter': 0, 'recentWorkspaces': []}


def save_server_state(state):
    """Save state to file."""
    try:
        with open(STATE_FILE, 'w') as f:
            json.dump(state, f)
    except Exception as e:
        print(f"Error saving state: {e}")


def check_tmux_available():
    """Check if tmux is available on the system."""
    return shutil.which('tmux') is not None


class WebTerminal:
    """PTY-based terminal that communicates over WebSocket."""
    
    def __init__(self):
        self.master_fd = None
        self.pid = None
        self.session_name = None
    
    def spawn(self, shell='/bin/bash', session_name=None):
        """Spawn a new PTY with shell, optionally using tmux for persistence."""
        self.session_name = session_name
        self.pid, self.master_fd = pty.fork()
        
        if self.pid == 0:
            # Child process
            home_dir = os.path.expanduser('~')
            os.chdir(home_dir)
            env = os.environ.copy()
            env['TERM'] = 'xterm-256color'
            env['HOME'] = home_dir
            
            if session_name and check_tmux_available():
                # Use tmux for persistent sessions
                # Check if session exists
                result = subprocess.run(
                    ['tmux', 'has-session', '-t', session_name],
                    capture_output=True
                )
                if result.returncode == 0:
                    # Session exists, attach to it
                    os.execvpe('tmux', ['tmux', 'attach-session', '-t', session_name], env)
                else:
                    # Create new session
                    os.execvpe('tmux', ['tmux', 'new-session', '-s', session_name], env)
            else:
                # Plain shell without tmux
                os.execvpe(shell, [shell], env)
        else:
            # Parent - set non-blocking
            flags = fcntl.fcntl(self.master_fd, fcntl.F_GETFL)
            fcntl.fcntl(self.master_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
    
    def spawn_command(self, command, args=[]):
        """Spawn a specific command in a PTY (for things like gpustat)."""
        self.pid, self.master_fd = pty.fork()
        
        if self.pid == 0:
            # Child process
            env = os.environ.copy()
            env['TERM'] = 'xterm-256color'
            
            # Execute the command
            cmd_path = shutil.which(command)
            if cmd_path:
                os.execvpe(cmd_path, [command] + args, env)
            else:
                # Command not found
                print(f"Error: {command} not found. Install it first.")
                os._exit(1)
        else:
            # Parent - set non-blocking
            flags = fcntl.fcntl(self.master_fd, fcntl.F_GETFL)
            fcntl.fcntl(self.master_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
    
    def resize(self, rows, cols):
        """Resize the PTY."""
        if self.master_fd:
            winsize = struct.pack('HHHH', rows, cols, 0, 0)
            fcntl.ioctl(self.master_fd, termios.TIOCSWINSZ, winsize)
    
    def write(self, data):
        """Write data to PTY."""
        if self.master_fd:
            os.write(self.master_fd, data.encode())
    
    def read(self):
        """Read available data from PTY."""
        if self.master_fd:
            try:
                return os.read(self.master_fd, 4096).decode('utf-8', errors='replace')
            except (OSError, BlockingIOError):
                return None
        return None
    
    def close(self):
        """Clean up PTY. For tmux sessions, just detach (session persists)."""
        if self.master_fd:
            os.close(self.master_fd)
        if self.pid:
            try:
                os.kill(self.pid, signal.SIGTERM)
                os.waitpid(self.pid, 0)
            except:
                pass
    
    @staticmethod
    def kill_session(session_name):
        """Kill a tmux session by name."""
        if session_name and check_tmux_available():
            subprocess.run(['tmux', 'kill-session', '-t', session_name], capture_output=True)


async def terminal_handler(request):
    """WebSocket handler for terminal connections."""
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    
    # Check if this is a gpustat request
    is_gpustat = request.query.get('gpustat', '') == '1'
    
    if is_gpustat:
        # Spawn gpustat command
        terminal = WebTerminal()
        terminal.spawn_command('gpustat', ['-f', '-c', '--watch'])
    else:
        # Get session name from query params for tmux persistence
        session_name = request.query.get('session', None)
        terminal = WebTerminal()
        terminal.spawn(session_name=session_name)
    
    # Read loop - send PTY output to WebSocket
    async def read_loop():
        while not ws.closed:
            output = terminal.read()
            if output:
                await ws.send_str(output)
            await asyncio.sleep(0.01)
    
    read_task = asyncio.create_task(read_loop())
    
    try:
        async for msg in ws:
            if msg.type == web.WSMsgType.TEXT:
                data = msg.json() if msg.data.startswith('{') else {'type': 'input', 'data': msg.data}
                
                if data.get('type') == 'resize':
                    terminal.resize(data.get('rows', 24), data.get('cols', 80))
                elif data.get('type') == 'input' and not is_gpustat:
                    # Only allow input for non-gpustat terminals
                    terminal.write(data.get('data', ''))
                elif not is_gpustat:
                    terminal.write(msg.data)
    finally:
        read_task.cancel()
        terminal.close()
    
    return ws


async def kill_session_handler(request):
    """API endpoint to kill a tmux session."""
    session_name = request.query.get('session', '')
    if session_name:
        WebTerminal.kill_session(session_name)
        return web.json_response({'status': 'ok', 'session': session_name})
    return web.json_response({'status': 'error', 'message': 'No session specified'}, status=400)


async def get_state_handler(request):
    """API endpoint to get server-side state."""
    state = load_server_state()
    return web.json_response(state)


async def save_state_handler(request):
    """API endpoint to save server-side state."""
    try:
        state = await request.json()
        save_server_state(state)
        return web.json_response({'status': 'ok'})
    except Exception as e:
        return web.json_response({'status': 'error', 'message': str(e)}, status=400)


async def list_dirs_handler(request):
    """API endpoint to list directories for autocomplete."""
    import json
    path = request.query.get('path', '')
    
    # Expand ~ to home directory
    if path.startswith('~'):
        path = os.path.expanduser(path)
    
    # If empty or just starting, suggest common root directories
    if not path or path == '/':
        dirs = []
        # Add common base directories
        for base in [os.path.expanduser('~'), '/data']:
            if os.path.isdir(base):
                dirs.append({
                    'name': base,
                    'path': base
                })
        return web.json_response({
            'base': '/',
            'dirs': dirs
        })
    
    # Determine what to list
    if os.path.isdir(path):
        base_dir = path
        prefix = ''
    else:
        base_dir = os.path.dirname(path) or '/'
        prefix = os.path.basename(path).lower()
    
    # List directories
    dirs = []
    try:
        if os.path.isdir(base_dir):
            for entry in os.scandir(base_dir):
                try:
                    if entry.is_dir() and not entry.name.startswith('.'):
                        if not prefix or entry.name.lower().startswith(prefix):
                            full_path = os.path.join(base_dir, entry.name)
                            dirs.append({
                                'name': entry.name,
                                'path': full_path
                            })
                except (PermissionError, OSError):
                    continue
    except (PermissionError, OSError):
        pass
    
    # Sort and limit
    dirs.sort(key=lambda x: x['name'].lower())
    dirs = dirs[:20]  # Limit to 20 suggestions
    
    return web.json_response({
        'base': base_dir,
        'dirs': dirs
    })


async def index_handler(request):
    """Serve the terminal web page."""
    html = '''<!DOCTYPE html>
<html>
<head>
    <title>rdock</title>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.min.css">
    <script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/xterm-addon-fit@0.8.0/lib/xterm-addon-fit.min.js"></script>
    <style>
        * { box-sizing: border-box; }
        html, body { margin: 0; padding: 0; background: #1e1e1e; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; height: 100%; overflow: hidden; }
        
        /* Tab bar */
        #tab-bar {
            position: fixed;
            top: 0;
            left: 0;
            right: 0;
            z-index: 100;
            display: flex;
            background: #252526;
            border-bottom: 1px solid #3c3c3c;
            height: 36px;
            align-items: center;
            padding: 0 8px;
            gap: 4px;
            overflow-x: auto;
        }
        
        .tab {
            display: flex;
            align-items: center;
            padding: 6px 12px;
            background: #2d2d2d;
            border: 1px solid #3c3c3c;
            border-bottom: none;
            border-radius: 6px 6px 0 0;
            color: #969696;
            cursor: pointer;
            font-size: 13px;
            gap: 8px;
            min-width: 100px;
            max-width: 200px;
            transition: all 0.15s;
        }
        
        .tab:hover { background: #383838; color: #ccc; }
        .tab.active { background: #1e1e1e; color: #fff; border-color: #007acc; border-bottom: 1px solid #1e1e1e; margin-bottom: -1px; }
        .tab.terminal-tab .tab-icon { color: #4ec9b0; }
        .tab.vscode-tab .tab-icon { color: #007acc; }
        
        .tab-icon { font-size: 14px; flex-shrink: 0; }
        .tab-title { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        
        .tab-close {
            width: 18px;
            height: 18px;
            border-radius: 4px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 16px;
            opacity: 0.6;
        }
        .tab-close:hover { background: #ff5f56; opacity: 1; color: #fff; }
        
        .new-tab-btn {
            width: 28px;
            height: 28px;
            background: transparent;
            border: 1px solid #3c3c3c;
            border-radius: 4px;
            color: #888;
            cursor: pointer;
            font-size: 14px;
            display: flex;
            align-items: center;
            justify-content: center;
            margin-left: 4px;
        }
        .new-tab-btn:hover { background: #383838; color: #fff; }
        #new-terminal-btn { color: #4ec9b0; }
        #new-vscode-btn { color: #007acc; }
        #gpustat-btn { color: #f59e0b; margin-left: auto; }
        
        .btn-separator {
            width: 1px;
            height: 20px;
            background: #3c3c3c;
            margin: 0 4px;
        }
        
        /* Content container */
        #content-container {
            position: fixed;
            top: 36px;
            left: 0;
            right: 0;
            bottom: 0;
        }
        
        .tab-content {
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            bottom: 0;
            display: none;
        }
        .tab-content.active { display: block; }
        
        .terminal-wrapper {
            height: 100%;
            padding: 10px;
        }
        .terminal-wrapper .xterm { height: 100%; }
        
        .vscode-wrapper {
            height: 100%;
            width: 100%;
        }
        .vscode-wrapper iframe {
            width: 100%;
            height: 100%;
            border: none;
        }
        
        /* Folder picker modal */
        #folder-modal {
            display: none;
            position: fixed;
            top: 0;
            left: 0;
            right: 0;
            bottom: 0;
            background: rgba(0,0,0,0.7);
            z-index: 200;
            align-items: center;
            justify-content: center;
        }
        #folder-modal.show { display: flex; }
        
        .modal-content {
            background: #2d2d2d;
            border: 1px solid #3c3c3c;
            border-radius: 8px;
            padding: 20px;
            min-width: 400px;
            max-width: 600px;
        }
        
        .modal-title {
            color: #fff;
            font-size: 16px;
            margin-bottom: 15px;
        }
        
        .modal-input {
            width: 100%;
            padding: 10px;
            background: #1e1e1e;
            border: 1px solid #3c3c3c;
            border-radius: 4px;
            color: #fff;
            font-size: 14px;
            margin-bottom: 15px;
        }
        .modal-input:focus { outline: none; border-color: #007acc; }
        
        .modal-buttons {
            display: flex;
            justify-content: flex-end;
            gap: 10px;
        }
        
        .modal-btn {
            padding: 8px 16px;
            border-radius: 4px;
            border: none;
            cursor: pointer;
            font-size: 13px;
        }
        .modal-btn-cancel { background: #3c3c3c; color: #ccc; }
        .modal-btn-cancel:hover { background: #4c4c4c; }
        .modal-btn-open { background: #007acc; color: #fff; }
        .modal-btn-open:hover { background: #0098ff; }
        
        /* Autocomplete styles */
        .input-wrapper {
            position: relative;
            margin-bottom: 15px;
        }
        .input-wrapper .modal-input {
            margin-bottom: 0;
        }
        
        #autocomplete-list {
            position: absolute;
            top: 100%;
            left: 0;
            right: 0;
            max-height: 200px;
            overflow-y: auto;
            background: #1e1e1e;
            border: 1px solid #3c3c3c;
            border-top: none;
            border-radius: 0 0 4px 4px;
            z-index: 10;
            display: none;
        }
        #autocomplete-list.show { display: block; }
        
        .autocomplete-item {
            padding: 8px 10px;
            color: #ccc;
            cursor: pointer;
            display: flex;
            align-items: center;
            gap: 8px;
            font-size: 13px;
        }
        .autocomplete-item:hover, .autocomplete-item.selected {
            background: #094771;
            color: #fff;
        }
        .autocomplete-item .folder-icon {
            color: #dcb67a;
        }
        .autocomplete-item .folder-path {
            color: #888;
            font-size: 11px;
            margin-left: auto;
        }
        
        /* Recent workspaces styles */
        .recent-workspaces {
            margin-bottom: 15px;
            max-height: 150px;
            overflow-y: auto;
        }
        .recent-header {
            color: #888;
            font-size: 11px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            margin-bottom: 8px;
            display: flex;
            align-items: center;
            gap: 6px;
        }
        .recent-header::after {
            content: '';
            flex: 1;
            height: 1px;
            background: #3c3c3c;
        }
        .recent-item {
            padding: 8px 10px;
            background: #1e1e1e;
            border: 1px solid #3c3c3c;
            border-radius: 4px;
            margin-bottom: 6px;
            cursor: pointer;
            display: flex;
            align-items: center;
            gap: 8px;
            transition: all 0.15s;
        }
        .recent-item:hover {
            background: #094771;
            border-color: #094771;
        }
        .recent-item .folder-icon { color: #dcb67a; }
        .recent-item .folder-name {
            color: #fff;
            font-size: 13px;
            flex: 1;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        .recent-item .folder-fullpath {
            color: #888;
            font-size: 11px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
            max-width: 200px;
        }
        .recent-item .remove-recent {
            color: #888;
            font-size: 14px;
            padding: 2px 6px;
            border-radius: 3px;
            opacity: 0;
            transition: opacity 0.15s;
        }
        .recent-item:hover .remove-recent { opacity: 1; }
        .recent-item .remove-recent:hover {
            background: #ff5f56;
            color: #fff;
        }
        .no-recent {
            color: #666;
            font-size: 12px;
            font-style: italic;
            padding: 8px 0;
        }
    </style>
</head>
<body>
    <div id="tab-bar">
        <button id="new-terminal-btn" class="new-tab-btn" title="New Terminal (Ctrl+Shift+T)">▶</button>
        <div class="btn-separator"></div>
        <button id="new-vscode-btn" class="new-tab-btn" title="New VS Code (Ctrl+Shift+E)">◇</button>
        <button id="gpustat-btn" class="new-tab-btn" title="GPU Stats (Ctrl+Shift+G)">🖥️</button>
    </div>
    <div id="content-container"></div>
    
    <!-- Folder picker modal for VS Code -->
    <div id="folder-modal">
        <div class="modal-content">
            <div class="modal-title">Open Folder in VS Code</div>
            <div id="recent-workspaces" class="recent-workspaces"></div>
            <div class="input-wrapper">
                <input type="text" id="folder-path" class="modal-input" placeholder="Start typing a path... (Tab to complete)" autocomplete="off">
                <div id="autocomplete-list"></div>
            </div>
            <div class="modal-buttons">
                <button class="modal-btn modal-btn-cancel" id="modal-cancel">Cancel</button>
                <button class="modal-btn modal-btn-open" id="modal-open">Open</button>
            </div>
        </div>
    </div>
    
    <script>
        // Base path for API calls (handles sub-path deployments like /rdock)
        const basePath = window.location.pathname.replace(/\\/$/, '') || '';
        
        const tabs = new Map(); // tabId -> { type, element, wrapper, ... }
        let activeTabId = null;
        let tabCounter = 0;
        let terminalCounter = 0;
        let vscodeCounter = 0;
        const RECENT_KEY = 'recentWorkspaces';
        const MAX_RECENT = 10;
        
        // Server-side state management
        async function loadServerState() {
            try {
                const resp = await fetch(basePath + '/state');
                if (resp.ok) {
                    return await resp.json();
                }
            } catch (e) {
                console.error('Failed to load server state:', e);
            }
            return null;
        }
        
        async function saveServerState() {
            const state = {
                tabs: [],
                activeTabId: activeTabId,
                tabCounter: tabCounter,
                terminalCounter: terminalCounter,
                vscodeCounter: vscodeCounter,
                recentWorkspaces: getRecentWorkspaces()
            };
            tabs.forEach((data, id) => {
                if (data.type === 'terminal') {
                    state.tabs.push({ id, type: 'terminal', sessionName: data.sessionName });
                } else if (data.type === 'vscode') {
                    state.tabs.push({ id, type: 'vscode', folderPath: data.folderPath });
                }
            });
            
            try {
                await fetch(basePath + '/state', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(state)
                });
            } catch (e) {
                console.error('Failed to save server state:', e);
            }
        }
        
        // Debounced save to avoid too many requests
        let saveTimeout = null;
        function saveState() {
            clearTimeout(saveTimeout);
            saveTimeout = setTimeout(saveServerState, 500);
        }
        
        // Recent workspaces management (now uses server state)
        let cachedRecentWorkspaces = [];
        
        function getRecentWorkspaces() {
            return cachedRecentWorkspaces;
        }
        
        function addRecentWorkspace(folderPath) {
            if (!folderPath) return;
            // Remove if already exists
            cachedRecentWorkspaces = cachedRecentWorkspaces.filter(p => p !== folderPath);
            // Add to front
            cachedRecentWorkspaces.unshift(folderPath);
            // Limit size
            cachedRecentWorkspaces = cachedRecentWorkspaces.slice(0, MAX_RECENT);
            saveState();
        }
        
        function removeRecentWorkspace(folderPath) {
            cachedRecentWorkspaces = cachedRecentWorkspaces.filter(p => p !== folderPath);
            saveState();
            renderRecentWorkspaces();
        }
        
        function renderRecentWorkspaces() {
            const container = document.getElementById('recent-workspaces');
            const recent = getRecentWorkspaces();
            
            if (recent.length === 0) {
                container.innerHTML = `
                    <div class="recent-header">Recent</div>
                    <div class="no-recent">No recent workspaces</div>
                `;
                return;
            }
            
            container.innerHTML = `
                <div class="recent-header">Recent</div>
                ${recent.map(path => {
                    const parts = path.split('/').filter(p => p);
                    const name = parts[parts.length - 1] || path;
                    return `
                        <div class="recent-item" data-path="${path}">
                            <span class="folder-icon">📁</span>
                            <span class="folder-name">${name}</span>
                            <span class="folder-fullpath">${path}</span>
                            <span class="remove-recent" data-path="${path}">×</span>
                        </div>
                    `;
                }).join('')}
            `;
            
            // Add click handlers
            container.querySelectorAll('.recent-item').forEach(item => {
                item.onclick = (e) => {
                    if (e.target.classList.contains('remove-recent')) {
                        e.stopPropagation();
                        removeRecentWorkspace(e.target.dataset.path);
                    } else {
                        createVSCodeTab(item.dataset.path);
                        hideFolderModal();
                    }
                };
            });
        }
        
        // Generate unique session name for tmux
        function generateSessionName() {
            return `webt_${Date.now()}_${Math.random().toString(36).substr(2, 6)}`;
        }
        
        function createTerminalTab(sessionName = null, tabTitle = null) {
            const tabId = `term-${++tabCounter}`;
            terminalCounter++;
            
            // Use provided session name or generate new one
            const session = sessionName || generateSessionName();
            const title = tabTitle || `Terminal ${terminalCounter}`;
            
            // Create tab element
            const tab = document.createElement('div');
            tab.className = 'tab terminal-tab';
            tab.innerHTML = `<span class="tab-icon">▶</span><span class="tab-title">${title}</span><span class="tab-close">×</span>`;
            tab.dataset.tabId = tabId;
            
            // Insert before buttons
            document.querySelector('.new-tab-btn').before(tab);
            
            // Create terminal wrapper
            const wrapper = document.createElement('div');
            wrapper.className = 'tab-content';
            wrapper.id = `content-${tabId}`;
            wrapper.innerHTML = '<div class="terminal-wrapper"></div>';
            document.getElementById('content-container').appendChild(wrapper);
            
            const termContainer = wrapper.querySelector('.terminal-wrapper');
            
            // Create terminal
            const term = new Terminal({
                cursorBlink: true,
                fontSize: 14,
                fontFamily: 'Menlo, Monaco, "Courier New", monospace',
                theme: { background: '#1e1e1e' }
            });
            const fitAddon = new FitAddon.FitAddon();
            term.loadAddon(fitAddon);
            term.open(termContainer);
            
            // Connect WebSocket with session name for tmux
            const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
            const ws = new WebSocket(`${protocol}//${location.host}${basePath}/terminal?session=${encodeURIComponent(session)}`);
            
            ws.onopen = () => {
                fitAddon.fit();
                ws.send(JSON.stringify({type: 'resize', rows: term.rows, cols: term.cols}));
            };
            
            ws.onmessage = (e) => term.write(e.data);
            ws.onclose = () => {
                term.write('\\r\\n[Connection closed - reload to reconnect]\\r\\n');
                tab.style.opacity = '0.5';
            };
            
            term.onData((data) => {
                if (ws.readyState === WebSocket.OPEN) {
                    ws.send(JSON.stringify({type: 'input', data: data}));
                }
            });
            
            // Store tab data with session name
            tabs.set(tabId, { type: 'terminal', term, fitAddon, ws, element: tab, wrapper, sessionName: session });
            
            // Tab click handlers
            tab.querySelector('.tab-title').onclick = () => activateTab(tabId);
            tab.querySelector('.tab-close').onclick = (e) => { e.stopPropagation(); closeTab(tabId); };
            
            activateTab(tabId);
            saveState();
            return tabId;
        }
        
        function createVSCodeTab(folderPath = '') {
            const tabId = `vscode-${++tabCounter}`;
            vscodeCounter++;
            
            // Add to recent workspaces
            if (folderPath) {
                addRecentWorkspace(folderPath);
            }
            
            // Build VS Code URL (use basePath for sub-path deployments)
            let vscodeUrl = basePath + '/code/';
            if (folderPath) {
                vscodeUrl += `?folder=${encodeURIComponent(folderPath)}`;
            }
            
            // Determine tab title
            let tabTitle = 'VS Code';
            if (folderPath) {
                const parts = folderPath.split('/').filter(p => p);
                tabTitle = parts[parts.length - 1] || 'VS Code';
            }
            if (vscodeCounter > 1) {
                tabTitle += ` ${vscodeCounter}`;
            }
            
            // Create tab element
            const tab = document.createElement('div');
            tab.className = 'tab vscode-tab';
            tab.innerHTML = `<span class="tab-icon">◇</span><span class="tab-title">${tabTitle}</span><span class="tab-close">×</span>`;
            tab.dataset.tabId = tabId;
            
            // Insert before buttons
            document.querySelector('.new-tab-btn').before(tab);
            
            // Create VS Code wrapper with iframe
            const wrapper = document.createElement('div');
            wrapper.className = 'tab-content';
            wrapper.id = `content-${tabId}`;
            wrapper.innerHTML = `<div class="vscode-wrapper"><iframe src="${vscodeUrl}" allow="clipboard-read; clipboard-write"></iframe></div>`;
            document.getElementById('content-container').appendChild(wrapper);
            
            // Store tab data
            tabs.set(tabId, { type: 'vscode', element: tab, wrapper, folderPath });
            
            // Tab click handlers
            tab.querySelector('.tab-title').onclick = () => activateTab(tabId);
            tab.querySelector('.tab-close').onclick = (e) => { e.stopPropagation(); closeTab(tabId); };
            
            activateTab(tabId);
            saveState();
            return tabId;
        }
        
        function createGPUStatTab() {
            const tabId = `gpustat-${++tabCounter}`;
            
            // Create tab element
            const tab = document.createElement('div');
            tab.className = 'tab terminal-tab';
            tab.innerHTML = `<span class="tab-icon">🖥️</span><span class="tab-title">GPU Stats</span><span class="tab-close">×</span>`;
            tab.dataset.tabId = tabId;
            
            // Insert before buttons
            document.querySelector('.new-tab-btn').before(tab);
            
            // Create terminal wrapper
            const wrapper = document.createElement('div');
            wrapper.className = 'tab-content';
            wrapper.id = `content-${tabId}`;
            wrapper.innerHTML = '<div class="terminal-wrapper"></div>';
            document.getElementById('content-container').appendChild(wrapper);
            
            const termContainer = wrapper.querySelector('.terminal-wrapper');
            
            // Create terminal
            const term = new Terminal({
                cursorBlink: false,
                fontSize: 14,
                fontFamily: 'Menlo, Monaco, "Courier New", monospace',
                theme: { background: '#1e1e1e' },
                disableStdin: true  // Read-only
            });
            const fitAddon = new FitAddon.FitAddon();
            term.loadAddon(fitAddon);
            term.open(termContainer);
            
            // Connect WebSocket for gpustat streaming
            const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
            const ws = new WebSocket(`${protocol}//${location.host}${basePath}/terminal?gpustat=1`);
            
            ws.onopen = () => {
                fitAddon.fit();
            };
            
            ws.onmessage = (e) => term.write(e.data);
            ws.onclose = () => {
                term.write('\\r\\n[GPU Stats stream closed]\\r\\n');
                tab.style.opacity = '0.5';
            };
            
            // Store tab data
            tabs.set(tabId, { type: 'gpustat', term, fitAddon, ws, element: tab, wrapper });
            
            // Tab click handlers
            tab.onclick = () => activateTab(tabId);
            tab.querySelector('.tab-title').onclick = () => activateTab(tabId);
            tab.querySelector('.tab-close').onclick = (e) => { e.stopPropagation(); closeTab(tabId); };
            
            activateTab(tabId);
            return tabId;
        }
        
        function activateTab(tabId) {
            if (activeTabId === tabId) return;
            
            // Deactivate previous
            if (activeTabId && tabs.has(activeTabId)) {
                const prev = tabs.get(activeTabId);
                prev.element.classList.remove('active');
                prev.wrapper.classList.remove('active');
            }
            
            // Activate new
            const current = tabs.get(tabId);
            if (current) {
                current.element.classList.add('active');
                current.wrapper.classList.add('active');
                activeTabId = tabId;
                
                // Focus terminal if it's a terminal tab
                if (current.type === 'terminal') {
                    setTimeout(() => {
                        current.fitAddon.fit();
                        current.term.focus();
                        if (current.ws.readyState === WebSocket.OPEN) {
                            current.ws.send(JSON.stringify({type: 'resize', rows: current.term.rows, cols: current.term.cols}));
                        }
                    }, 10);
                }
                
                saveState();
            }
        }
        
        function closeTab(tabId, killSession = true) {
            const tab = tabs.get(tabId);
            if (!tab) return;
            
            // Cleanup based on type
            if (tab.type === 'terminal') {
                if (tab.ws.readyState === WebSocket.OPEN) {
                    tab.ws.close();
                }
                tab.term.dispose();
                
                // Kill the tmux session when explicitly closing tab
                if (killSession && tab.sessionName) {
                    fetch(`${basePath}/kill-session?session=${encodeURIComponent(tab.sessionName)}`);
                }
            }
            
            // Remove DOM elements
            tab.element.remove();
            tab.wrapper.remove();
            tabs.delete(tabId);
            
            // Activate another tab if this was active
            if (activeTabId === tabId) {
                activeTabId = null;
                const remaining = Array.from(tabs.keys());
                if (remaining.length > 0) {
                    activateTab(remaining[remaining.length - 1]);
                }
            }
            
            // Create terminal if none left
            if (tabs.size === 0) {
                createTerminalTab();
            }
            
            saveState();
        }
        
        // Handle window resize
        window.addEventListener('resize', () => {
            if (activeTabId && tabs.has(activeTabId)) {
                const current = tabs.get(activeTabId);
                if (current.type === 'terminal') {
                    current.fitAddon.fit();
                    if (current.ws.readyState === WebSocket.OPEN) {
                        current.ws.send(JSON.stringify({type: 'resize', rows: current.term.rows, cols: current.term.cols}));
                    }
                }
            }
        });
        
        // Folder modal handling with autocomplete
        const folderModal = document.getElementById('folder-modal');
        const folderInput = document.getElementById('folder-path');
        const autocompleteList = document.getElementById('autocomplete-list');
        let autocompleteItems = [];
        let selectedIndex = -1;
        let fetchTimeout = null;
        
        function showFolderModal() {
            folderInput.value = '';
            folderModal.classList.add('show');
            folderInput.focus();
            hideAutocomplete();
            // Render recent workspaces
            renderRecentWorkspaces();
            // Fetch initial suggestions (home directory)
            fetchSuggestions('');
        }
        
        function hideFolderModal() {
            folderModal.classList.remove('show');
            hideAutocomplete();
        }
        
        function hideAutocomplete() {
            autocompleteList.classList.remove('show');
            autocompleteList.innerHTML = '';
            autocompleteItems = [];
            selectedIndex = -1;
        }
        
        async function fetchSuggestions(path) {
            try {
                const resp = await fetch(`${basePath}/list-dirs?path=${encodeURIComponent(path)}`);
                const data = await resp.json();
                showSuggestions(data.dirs, data.base);
            } catch (e) {
                hideAutocomplete();
            }
        }
        
        function showSuggestions(dirs, basePath) {
            if (dirs.length === 0) {
                hideAutocomplete();
                return;
            }
            
            autocompleteItems = dirs;
            selectedIndex = -1;
            autocompleteList.innerHTML = dirs.map((d, i) => `
                <div class="autocomplete-item" data-index="${i}" data-path="${d.path}">
                    <span class="folder-icon">📁</span>
                    <span class="folder-name">${d.name}</span>
                    <span class="folder-path">${basePath}</span>
                </div>
            `).join('');
            autocompleteList.classList.add('show');
            
            // Add click handlers
            autocompleteList.querySelectorAll('.autocomplete-item').forEach(item => {
                item.onclick = () => selectItem(parseInt(item.dataset.index));
            });
        }
        
        function selectItem(index) {
            if (index >= 0 && index < autocompleteItems.length) {
                folderInput.value = autocompleteItems[index].path + '/';
                folderInput.focus();
                // Fetch new suggestions for the selected directory
                fetchSuggestions(folderInput.value);
            }
        }
        
        function updateSelection(newIndex) {
            const items = autocompleteList.querySelectorAll('.autocomplete-item');
            items.forEach(item => item.classList.remove('selected'));
            
            if (newIndex >= 0 && newIndex < items.length) {
                selectedIndex = newIndex;
                items[selectedIndex].classList.add('selected');
                items[selectedIndex].scrollIntoView({ block: 'nearest' });
            } else {
                selectedIndex = -1;
            }
        }
        
        folderInput.addEventListener('input', () => {
            clearTimeout(fetchTimeout);
            fetchTimeout = setTimeout(() => {
                fetchSuggestions(folderInput.value);
            }, 150);
        });
        
        folderInput.addEventListener('keydown', (e) => {
            const isAutocompleteVisible = autocompleteList.classList.contains('show');
            
            if (e.key === 'ArrowDown' && isAutocompleteVisible) {
                e.preventDefault();
                updateSelection(Math.min(selectedIndex + 1, autocompleteItems.length - 1));
            } else if (e.key === 'ArrowUp' && isAutocompleteVisible) {
                e.preventDefault();
                updateSelection(Math.max(selectedIndex - 1, 0));
            } else if (e.key === 'Tab' && isAutocompleteVisible && autocompleteItems.length > 0) {
                e.preventDefault();
                if (selectedIndex >= 0) {
                    selectItem(selectedIndex);
                } else if (autocompleteItems.length === 1) {
                    selectItem(0);
                } else {
                    updateSelection(0);
                }
            } else if (e.key === 'Enter') {
                if (isAutocompleteVisible && selectedIndex >= 0) {
                    e.preventDefault();
                    selectItem(selectedIndex);
                } else {
                    createVSCodeTab(folderInput.value.trim());
                    hideFolderModal();
                }
            } else if (e.key === 'Escape') {
                if (isAutocompleteVisible) {
                    hideAutocomplete();
                } else {
                    hideFolderModal();
                }
            }
        });
        
        document.getElementById('modal-cancel').onclick = hideFolderModal;
        document.getElementById('modal-open').onclick = () => {
            createVSCodeTab(folderInput.value.trim());
            hideFolderModal();
        };
        
        folderModal.onclick = (e) => {
            if (e.target === folderModal) hideFolderModal();
        };
        
        // Keyboard shortcuts
        document.addEventListener('keydown', (e) => {
            // Detect Cmd (Mac) or Ctrl (Win/Linux)
            const isMac = navigator.platform.toUpperCase().indexOf('MAC') >= 0;
            const modKey = isMac ? e.metaKey : e.ctrlKey;
            
            // Cmd/Ctrl+W: Close current tab (override browser close)
            if (modKey && !e.shiftKey && e.key.toLowerCase() === 'w') {
                e.preventDefault();
                e.stopPropagation();
                if (activeTabId) closeTab(activeTabId);
                return false;
            }
            // Cmd/Ctrl+Shift+W: Also close current tab
            if (modKey && e.shiftKey && e.key.toLowerCase() === 'w') {
                e.preventDefault();
                e.stopPropagation();
                if (activeTabId) closeTab(activeTabId);
                return false;
            }
            // Ctrl+Shift+T: New terminal
            if (e.ctrlKey && e.shiftKey && e.key === 'T') {
                e.preventDefault();
                createTerminalTab();
            }
            // Ctrl+Shift+E: New VS Code
            if (e.ctrlKey && e.shiftKey && e.key === 'E') {
                e.preventDefault();
                showFolderModal();
            }
            // Ctrl+Shift+G: GPU Stats
            if (e.ctrlKey && e.shiftKey && e.key === 'G') {
                e.preventDefault();
                createGPUStatTab();
            }
            // Cmd/Ctrl+T: New terminal (override browser new tab)
            if (modKey && !e.shiftKey && e.key.toLowerCase() === 't') {
                e.preventDefault();
                e.stopPropagation();
                createTerminalTab();
                return false;
            }
            // Ctrl+Tab: Next tab
            if (e.ctrlKey && e.key === 'Tab' && !e.shiftKey) {
                e.preventDefault();
                const ids = Array.from(tabs.keys());
                const idx = ids.indexOf(activeTabId);
                if (idx >= 0 && ids.length > 1) {
                    activateTab(ids[(idx + 1) % ids.length]);
                }
            }
            // Ctrl+Shift+Tab: Previous tab
            if (e.ctrlKey && e.shiftKey && e.key === 'Tab') {
                e.preventDefault();
                const ids = Array.from(tabs.keys());
                const idx = ids.indexOf(activeTabId);
                if (idx >= 0 && ids.length > 1) {
                    activateTab(ids[(idx - 1 + ids.length) % ids.length]);
                }
            }
        }, true); // Use capture phase to intercept before browser
        
        // Button handlers
        document.getElementById('new-terminal-btn').onclick = () => createTerminalTab();
        document.getElementById('new-vscode-btn').onclick = showFolderModal;
        document.getElementById('gpustat-btn').onclick = () => createGPUStatTab();
        
        // Restore state or create first terminal tab
        async function init() {
            const state = await loadServerState();
            if (state && state.tabs && state.tabs.length > 0) {
                // Restore counters
                tabCounter = state.tabCounter || 0;
                terminalCounter = 0; // Will be incremented as tabs are created
                vscodeCounter = 0;
                
                // Restore recent workspaces
                cachedRecentWorkspaces = state.recentWorkspaces || [];
                
                // Restore tabs
                state.tabs.forEach(tabData => {
                    if (tabData.type === 'terminal') {
                        createTerminalTab(tabData.sessionName);
                    } else if (tabData.type === 'vscode') {
                        createVSCodeTab(tabData.folderPath);
                    }
                });
                
                // Restore active tab
                if (state.activeTabId && tabs.has(state.activeTabId)) {
                    activateTab(state.activeTabId);
                }
            } else {
                // No saved state, create first terminal
                createTerminalTab();
            }
        }
        
        init();
    </script>
</body>
</html>'''
    return web.Response(text=html, content_type='text/html')


async def login_page_handler(request):
    """Serve the login page."""
    server_info = get_server_info()
    base_path = BASE_PATH  # For use in template
    error_msg = request.query.get('error', '')
    
    error_html = ''
    if error_msg:
        error_html = f'<div class="error-msg">{error_msg}</div>'
    
    html = f'''<!DOCTYPE html>
<html>
<head>
    <title>Login - {server_info['hostname']}</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        * {{ box-sizing: border-box; margin: 0; padding: 0; }}
        
        body {{
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            background: #0d0d0d;
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            color: #e0e0e0;
        }}
        
        .login-container {{
            width: 100%;
            max-width: 380px;
            padding: 20px;
        }}
        
        .login-card {{
            background: #161616;
            border-radius: 12px;
            padding: 40px 32px;
            border: 1px solid #262626;
        }}
        
        .server-info {{
            text-align: center;
            margin-bottom: 32px;
        }}
        
        .server-icon {{
            width: 48px;
            height: 48px;
            background: #262626;
            border-radius: 10px;
            display: flex;
            align-items: center;
            justify-content: center;
            margin: 0 auto 16px;
            font-size: 22px;
        }}
        
        .server-name {{
            font-size: 18px;
            font-weight: 600;
            color: #fff;
            margin-bottom: 4px;
            font-family: 'SF Mono', Monaco, 'Cascadia Code', monospace;
        }}
        
        .server-user {{
            font-size: 13px;
            color: #666;
        }}
        
        .form-group {{
            margin-bottom: 16px;
        }}
        
        .form-label {{
            display: block;
            font-size: 12px;
            font-weight: 500;
            color: #888;
            margin-bottom: 6px;
        }}
        
        .form-input {{
            width: 100%;
            padding: 12px 14px;
            background: #0d0d0d;
            border: 1px solid #333;
            border-radius: 8px;
            color: #fff;
            font-size: 15px;
            transition: border-color 0.15s ease;
        }}
        
        .form-input:focus {{
            outline: none;
            border-color: #525252;
        }}
        
        .form-input::placeholder {{
            color: #4a4a4a;
        }}
        
        .login-btn {{
            width: 100%;
            padding: 12px;
            background: #fff;
            border: none;
            border-radius: 8px;
            color: #0d0d0d;
            font-size: 14px;
            font-weight: 600;
            cursor: pointer;
            transition: opacity 0.15s ease;
            margin-top: 8px;
        }}
        
        .login-btn:hover {{
            opacity: 0.9;
        }}
        
        .error-msg {{
            background: rgba(220, 38, 38, 0.1);
            border: 1px solid rgba(220, 38, 38, 0.2);
            color: #ef4444;
            padding: 10px 14px;
            border-radius: 8px;
            font-size: 13px;
            margin-bottom: 16px;
            text-align: center;
        }}
        
        .status {{
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 6px;
            margin-top: 12px;
            font-size: 12px;
            color: #525252;
        }}
        
        .status-dot {{
            width: 6px;
            height: 6px;
            background: #22c55e;
            border-radius: 50%;
        }}
    </style>
</head>
<body>
    <div class="login-container">
        <div class="login-card">
            <div class="server-info">
                <div class="server-icon">⬢</div>
                <div class="server-name">{server_info['hostname']}</div>
                <div class="server-user">{server_info['user']}</div>
            </div>
            
            {error_html}
            
            <form method="POST" action="{base_path}/login">
                <div class="form-group">
                    <label class="form-label">Username</label>
                    <input type="text" name="username" class="form-input" placeholder="username" required autofocus>
                </div>
                <div class="form-group">
                    <label class="form-label">Password</label>
                    <input type="password" name="password" class="form-input" placeholder="••••••••" required>
                </div>
                <button type="submit" class="login-btn">Sign in</button>
            </form>
            
            <div class="status">
                <div class="status-dot"></div>
                rdock
            </div>
        </div>
    </div>
</body>
</html>'''
    return web.Response(text=html, content_type='text/html')


async def login_handler(request):
    """Handle login form submission."""
    home_url = f'{BASE_PATH}/' if BASE_PATH else '/'
    login_url = f'{BASE_PATH}/login' if BASE_PATH else '/login'
    
    # If no htpasswd file exists, allow access without auth
    if not htpasswd_exists():
        session_id = create_session('anonymous')
        response = web.HTTPFound(home_url)
        response.set_cookie('session_id', session_id, max_age=86400*30, httponly=True)
        return response
    
    data = await request.post()
    username = data.get('username', '')
    password = data.get('password', '')
    
    if verify_htpasswd(username, password):
        session_id = create_session(username)
        response = web.HTTPFound(home_url)
        response.set_cookie('session_id', session_id, max_age=86400*30, httponly=True)  # 30 days
        return response
    else:
        return web.HTTPFound(f'{login_url}?error=Invalid%20username%20or%20password')


async def logout_handler(request):
    """Handle logout."""
    login_url = f'{BASE_PATH}/login' if BASE_PATH else '/login'
    session_id = request.cookies.get('session_id')
    if session_id and session_id in SESSIONS:
        del SESSIONS[session_id]
    response = web.HTTPFound(login_url)
    response.del_cookie('session_id')
    return response


async def auth_middleware(app, handler):
    """Middleware to check authentication."""
    async def middleware_handler(request):
        # Login page is always accessible
        if request.path == '/login':
            return await handler(request)
        
        # If no htpasswd file, allow access (fall back to nginx auth if configured)
        if not htpasswd_exists():
            return await handler(request)
        
        # Check session
        if not verify_session(request):
            # For API/WebSocket, return 401
            if request.path in ['/terminal', '/state', '/list-dirs', '/kill-session']:
                return web.json_response({'error': 'Unauthorized'}, status=401)
            # Redirect to login with base path
            login_url = f'{BASE_PATH}/login' if BASE_PATH else '/login'
            return web.HTTPFound(login_url)
        
        return await handler(request)
    
    return middleware_handler


# Create app
app = web.Application(middlewares=[auth_middleware])
app.router.add_get('/', index_handler)
app.router.add_get('/login', login_page_handler)
app.router.add_post('/login', login_handler)
app.router.add_get('/logout', logout_handler)
app.router.add_get('/terminal', terminal_handler)
app.router.add_get('/list-dirs', list_dirs_handler)
app.router.add_get('/kill-session', kill_session_handler)
app.router.add_get('/state', get_state_handler)
app.router.add_post('/state', save_state_handler)

if __name__ == '__main__':
    port = int(os.environ.get('RDOCK_PORT', 8890))
    web.run_app(app, host='0.0.0.0', port=port)
