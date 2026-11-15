const input = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
for (const [key, template] of Object.entries(input.environment)) {
  process.env[key] = template.replace(/\$\{\{\s*(.*?)\s*\}\}/g, (_, expression) => {
    const value = expression.replace(/\binputs\.([\w-]+)/g, 'inputs["$1"]');
    return new Function('inputs', 'github', 'runner', 'steps', `return (${value});`)(
      input.inputs, { event: input.context.payload }, { temp: '/tmp' }, { verify_provenance: { outcome: 'skipped' } }
    );
  });
}
const result = { calls: [], failures: [] };
const record = (method, data) => async args => {
  result.calls.push({ method, ...args });
  return { data };
};
const github = { rest: { pulls: { get: async () => ({ data: {
  head: { sha: 'abc123', ref: 'contribution', repo: { id: 42 } },
  base: { ref: 'main' }
} }) }, issues: {
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
