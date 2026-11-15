const AsyncFunction = (async () => {}).constructor;
const fs = require('node:fs');
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const result = { failures: [], calls: [], skipped: false };
const runner = { temp: fs.mkdtempSync(require('node:path').join(require('node:os').tmpdir(), 'danger-workflow-')) };
const steps = { verify_provenance: { outcome: 'skipped' } };
const githubContext = {
  event_name: input.context.eventName,
  event: input.context.payload,
  repository: `${input.context.repo.owner}/${input.context.repo.repo}`,
  token: 'test-token'
};

function evaluate(expression, github = githubContext) {
  const value = expression.replace(/\binputs\.([\w-]+)/g, 'inputs["$1"]');
  return new Function('inputs', 'github', 'runner', 'steps', 'secrets', `return (${value});`)(
    input.inputs, github, runner, steps, { GITHUB_TOKEN: 'test-token' }
  );
}

function environment(templates, github = githubContext) {
  return Object.fromEntries(Object.entries(templates).map(([key, template]) =>
    [key, template.replace(/\$\{\{\s*(.*?)\s*\}\}/g, (_, expression) => evaluate(expression, github))]
  ));
}

function verifyProvenance() {
  const step = input.verification;
  if (!evaluate(step.if)) return true;
  const env = environment(step.env);
  if (input.provenance !== undefined) {
    fs.mkdirSync(require('node:path').dirname(env.PROVENANCE_PATH), { recursive: true });
    fs.writeFileSync(env.PROVENANCE_PATH, JSON.stringify(input.provenance));
    if (!input.bundleMissing) fs.writeFileSync(env.PROVENANCE_BUNDLE_PATH, '{}');
  }
  fs.writeFileSync(`${runner.temp}/gh`, `#!/usr/bin/env node
const fs = require('node:fs');
fs.writeFileSync(process.env.ARGV_PATH, JSON.stringify(process.argv.slice(2)));
process.exit(fs.existsSync(process.env.PROVENANCE_PATH) && fs.existsSync(process.env.PROVENANCE_BUNDLE_PATH) ? Number(process.env.VERIFICATION_EXIT) : 1);
`, { mode: 0o755 });
  const verification = require('node:child_process').spawnSync('bash', ['--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', step.run], {
    encoding: 'utf8',
    env: { ...process.env, ...env,
      PATH: `${runner.temp}:${process.env.PATH}`,
      GITHUB_REPOSITORY: githubContext.repository,
      GITHUB_SERVER_URL: input.context.serverUrl,
      VERIFICATION_EXIT: String(input.verificationExit || 0),
      ARGV_PATH: `${runner.temp}/arguments.json`
    }
  });
  if (fs.existsSync(`${runner.temp}/arguments.json`)) {
    result.verificationArguments = JSON.parse(fs.readFileSync(`${runner.temp}/arguments.json`, 'utf8'));
  }
  steps.verify_provenance.outcome = verification.status === 0 ? 'success' : 'failure';
  if (verification.status !== 0) result.failures.push('Attestation verification failed');
  return verification.status === 0;
}

async function main() {
  if (!evaluate(input.condition)) {
    result.skipped = true;
    return;
  }
  if (input.producer) {
    Object.assign(process.env, environment(input.producer.environment, { run_attempt: input.producer.context.runAttempt }));
    await new AsyncFunction('require', 'context', input.producer.script)(
      () => ({ writeFileSync: (_, data) => { result.producedProvenance = JSON.parse(data); } }),
      input.producer.context
    );
    input.provenance = result.producedProvenance;
  }
  if (!verifyProvenance()) return;
  Object.assign(process.env, environment(input.environment));
  const record = (method, response) => async args => {
    result.calls.push({ method, ...args });
    if (method === 'get' && input.apiError) throw new Error('Pull request unavailable');
    return { data: response };
  };
  const github = { rest: {
    pulls: { get: record('get', input.pr) },
    issues: {
      listComments: record('listComments', input.comments),
      createComment: record('createComment'),
      updateComment: record('updateComment')
    }
  } };
  github.paginate = async (method, args) => (await method(args)).data;
  const workflowFs = {
    existsSync: path => path === process.env.REPORT_PATH || fs.existsSync(path),
    readFileSync: path => path === process.env.REPORT_PATH ? JSON.stringify(input.report) : fs.readFileSync(path, 'utf8')
  };
  await new AsyncFunction('require', 'context', 'github', 'core', input.script)(
    name => { if (name === 'fs') return workflowFs; throw new Error(`Unexpected module: ${name}`); },
    input.context, github, { setFailed: message => result.failures.push(message) }
  );
}

main().catch(error => result.failures.push(error.message))
  .finally(() => fs.rmSync(runner.temp, { recursive: true, force: true }))
  .then(() => process.stdout.write(JSON.stringify(result)));
