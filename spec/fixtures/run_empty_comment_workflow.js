const input = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
Object.assign(process.env, input.environment);
const result = { calls: [], failures: [] };
const record = (method, data) => async args => {
  result.calls.push({ method, ...args });
  return { data };
};
const github = { rest: { issues: {
  listComments: record('listComments', input.comments),
  createComment: record('createComment'),
  updateComment: record('updateComment')
} } };
github.paginate = async (method, args) => (await method(args)).data;
const fs = { existsSync: () => true, readFileSync: () => JSON.stringify(input.report) };
const AsyncFunction = (async () => {}).constructor;

new AsyncFunction('require', 'context', 'github', 'core', input.script)(
  name => { if (name === 'fs') return fs; throw new Error(`Unexpected module: ${name}`); },
  input.context, github, { setFailed: message => result.failures.push(message) }
).catch(error => result.failures.push(error.message))
  .then(() => process.stdout.write(JSON.stringify(result)));
