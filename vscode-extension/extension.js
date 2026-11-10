// Tells Claude Code Pulse which Claude tab the front VS Code window shows. The app closes the notifications of that
// session and sends none for it while the tab stays in front. It also tells the app which windows are open, so that a
// click on a session in the app opens its chat in the window of its folder.
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

// The folders and the workspace file of the window.
function thisWindow() {
	return {
		folders: (vscode.workspace.workspaceFolders ?? []).map((folder) => folder.uri.fsPath),
		workspaceFile: vscode.workspace.workspaceFile?.scheme === 'file' ? vscode.workspace.workspaceFile.fsPath : null,
	};
}

// The last bodies that the app received, by event. A failed request sends again with the next change.
const lastBodies = {};

function report() {
	send('TabFocus', JSON.stringify({ hook_event_name: 'TabFocus', tab: focusedTab() }));
	send('Window', JSON.stringify({ hook_event_name: 'Window', window: thisWindow(), focused: vscode.window.state.focused }));
}

function send(name, body) {
	if (body === lastBodies[name]) return;
	lastBodies[name] = body;
	return post(body, () => { lastBodies[name] = undefined; });
}

function post(body, onError) {
	return new Promise((resolve) => {
		const request = http.request({
			host: '127.0.0.1', port: PORT, path: '/event', method: 'POST', timeout: 1000,
			headers: { 'X-Claude-Hook': '1', 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
		}, (response) => { response.resume(); resolve(); });
		request.on('error', () => { onError?.(); resolve(); });
		request.on('timeout', () => request.destroy());
		request.end(body);
	});
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

// VS Code waits for the promise when the window closes.
function deactivate() {
	return post(JSON.stringify({ hook_event_name: 'Window', window: thisWindow(), focused: false, closed: true }));
}

module.exports = { activate, deactivate };
