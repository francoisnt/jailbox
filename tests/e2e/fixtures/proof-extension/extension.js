// jailbox e2e proof extension, run by editor-smoke.sh inside the remote
// extension host. Its job is to prove the user-level guarantee: an editor
// opened through jailbox can execute a shell task in the mounted repo. On
// activation it writes an activation marker into the workspace, obtains the
// validation task — from .vscode/tasks.json when the editor discovers it in
// time, otherwise defined equivalently via the vscode.tasks API (recorded as
// task_source; diagnostic-only, not a pass/fail signal) — runs it, and
// records the task's real exit code. Unlike `codium --command ...` (which is
// fire-and-forget), every step here has an acknowledgment: activation is a
// guaranteed extension-host lifecycle event, and onDidEndTaskProcess reports
// whether the task process ran and how it exited.
//
// Result files are written atomically (tmp + rename) so the host-side test
// never reads a partial file through the bind mount.

const vscode = require('vscode');
const fs = require('fs');
const path = require('path');

// Must match the task label in the tasks.json fixture written by
// editor-smoke.sh:write_fixture and the marker names in editor-smoke.sh.
const TASK_LABEL = 'jailbox: validate remote session';
const ACTIVATION_MARKER = '.jailbox-editor-ext-activated';
const TASK_RESULT = '.jailbox-editor-task-result';
const TASK_DISCOVERY_MS = 45000;
// fetchTasks() can hang while task providers initialize; bound each call so
// the discovery loop actually retries instead of one call eating the budget.
const FETCH_ATTEMPT_TIMEOUT_MS = 5000;

function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

function writeFileAtomic(dir, name, lines) {
    const tmp = path.join(dir, name + '.tmp');
    fs.writeFileSync(tmp, lines.join('\n') + '\n');
    fs.renameSync(tmp, path.join(dir, name));
}

async function findTask(deadline) {
    const stats = { task: undefined, attempts: 0, timeouts: 0, lastNames: [] };
    while (Date.now() < deadline) {
        stats.attempts += 1;
        const tasks = await Promise.race([
            vscode.tasks.fetchTasks(),
            sleep(FETCH_ATTEMPT_TIMEOUT_MS).then(() => undefined),
        ]);
        if (tasks === undefined) {
            stats.timeouts += 1;
        } else {
            stats.lastNames = tasks.map((t) => t.name);
            stats.task = tasks.find((t) => t.name === TASK_LABEL);
            if (stats.task) {
                return stats;
            }
        }
        await sleep(1000);
    }
    return stats;
}

// Fallback when tasks.json discovery times out: an identical task built
// through the API. Executing it still proves the editor's task and terminal
// machinery works in the remote workspace; only tasks.json discovery is
// bypassed, and task_source records that.
function synthesizeTask(folder) {
    return new vscode.Task(
        { type: 'shell', task: 'jailbox-editor-proof-fallback' },
        folder,
        TASK_LABEL,
        'jailbox',
        new vscode.ShellExecution('bash .vscode/jailbox-validate.sh', { cwd: folder.uri.fsPath })
    );
}

function runTask(task) {
    return new Promise((resolve, reject) => {
        const sub = vscode.tasks.onDidEndTaskProcess((e) => {
            if (e.execution.task.name === TASK_LABEL) {
                sub.dispose();
                resolve(e.exitCode);
            }
        });
        vscode.tasks.executeTask(task).then(undefined, (err) => {
            sub.dispose();
            reject(err);
        });
    });
}

async function activate() {
    const folder = (vscode.workspace.workspaceFolders || [])[0];
    if (!folder || folder.uri.scheme !== 'file') {
        return;
    }
    const root = folder.uri.fsPath;

    let runId = '';
    try {
        runId = fs.readFileSync(path.join(root, '.jailbox-editor-run-id'), 'utf8').trim();
    } catch {
        // leave runId empty; the host-side run_id assertion will fail loudly
    }

    writeFileAtomic(root, ACTIVATION_MARKER, [
        `run_id=${runId}`,
        `remote_name=${vscode.env.remoteName || ''}`,
        `app_name=${vscode.env.appName}`,
        `activated_utc=${new Date().toISOString()}`,
    ]);

    // The test reloads the window to activate this extension, and a late
    // reload can re-activate it; don't re-run the task once a full result
    // from a previous activation exists.
    if (fs.existsSync(path.join(root, TASK_RESULT))) {
        return;
    }

    const result = [`run_id=${runId}`];
    result.push(`workspace_trusted=${vscode.workspace.isTrusted ? 'yes' : 'no'}`);
    try {
        const stats = await findTask(Date.now() + TASK_DISCOVERY_MS);
        result.push(`fetch_attempts=${stats.attempts}`);
        result.push(`fetch_timeouts=${stats.timeouts}`);
        let task = stats.task;
        if (task) {
            result.push('task_found=yes');
            result.push('task_source=workspace');
        } else {
            result.push('task_found=no');
            result.push(`fetched_task_names=${stats.lastNames.join(',')}`);
            result.push('task_source=synthesized');
            task = synthesizeTask(folder);
        }
        const exitCode = await runTask(task);
        result.push(`task_exit_code=${exitCode}`);
    } catch (err) {
        result.push(`task_error=${err && err.message ? err.message : String(err)}`);
    }
    writeFileAtomic(root, TASK_RESULT, result);
}

function deactivate() {}

module.exports = { activate, deactivate };
