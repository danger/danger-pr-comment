const input = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
for (const [key, template] of Object.entries(input.environment)) {
  process.env[key] = template.replace(/\$\{\{\s*(.*?)\s*\}\}/g, (_, expression) => {
    const value = expression.replace(/\binputs\.([\w-]+)/g, 'inputs["$1"]');
    return new Function('inputs', 'github', `return (${value});`)(input.inputs, { event: input.context.payload });
  });
}
const result = { calls: [], failures: [] };
const record = (method, data) => async args => {
  result.calls.push({ method, ...args });
  return { data };
};
const run = input.context.payload.workflow_run;
const pr = {
  number: input.report.pr_number, state: 'open', created_at: '2026-11-15T09:00:00Z',
  head: { sha: run.head_sha, ref: run.head_branch, repo: run.head_repository },
  base: { ref: 'main', repo: { id: input.context.payload.repository.id } }
};
const github = { rest: { pulls: {
  list: async () => ({ data: [pr] }),
  get: async () => ({ data: pr })
}, issues: {
  listComments: record('listComments', input.comments),
  createComment: record('createComment'),
  updateComment: record('updateComment'),
  deleteComment: record('deleteComment')
} } };
github.paginate = async (method, args) => (await method(args)).data;
const fs = { existsSync: () => true, readFileSync: () => JSON.stringify(input.report) };
const AsyncFunction = (async () => {}).constructor;

new AsyncFunction('require', 'context', 'github', 'core', input.script)(
  name => { if (name === 'fs') return fs; throw new Error(`Unexpected module: ${name}`); },
  input.context, github, { setFailed: message => result.failures.push(message) }
).catch(error => result.failures.push(error.message))
  .then(() => process.stdout.write(JSON.stringify(result)));
