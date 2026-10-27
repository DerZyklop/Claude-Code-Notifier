// Tells Claude Code Pulse which Claude tab the front VS Code window shows. The app closes the notifications of that
// session and sends none for it while the tab stays in front.
const vscode = require('vscode');
const http = require('http');

// The port of the app, see `eventPort` in the app.
const PORT = 47823;

// The active Claude tab of the window, or `null` while the window is in the background or shows another tab.
function focusedTab() {
	if (!vscode.window.state.focused) return null;
	const tab = vscode.window.tabGroups.activeTabGroup.activeTab;
	if (!(tab?.input instanceof vscode.TabInputWebview) || !tab.input.viewType.endsWith('claudeVSCodePanel')) return null;
	return { title: tab.label, folders: (vscode.workspace.workspaceFolders ?? []).map((folder) => folder.uri.fsPath) };
}

// The last body that the app received. A failed request sends again with the next change.
let lastBody;

function report() {
	const body = JSON.stringify({ hook_event_name: 'TabFocus', tab: focusedTab() });
	if (body === lastBody) return;
	lastBody = body;
	const request = http.request({
		host: '127.0.0.1', port: PORT, path: '/event', method: 'POST', timeout: 1000,
		headers: { 'X-Claude-Hook': '1', 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
	});
	request.on('error', () => { lastBody = undefined; });
	request.on('timeout', () => request.destroy());
	request.end(body);
}

function activate(context) {
	context.subscriptions.push(
		vscode.window.onDidChangeWindowState(report),
		vscode.window.tabGroups.onDidChangeTabs(report),
		vscode.window.tabGroups.onDidChangeTabGroups(report),
		vscode.workspace.onDidChangeWorkspaceFolders(report),
	);
	report();
}

module.exports = { activate };
