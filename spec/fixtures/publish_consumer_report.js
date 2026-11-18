const input = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
const step = input.workflow.jobs.comment.steps.at(-1);
const definition = (input.workflow.on || input.workflow.true).workflow_call.inputs;
const inputs = { ...Object.fromEntries(Object.entries(definition).map(([key, value]) => [key, value.default])), ...input.inputs };
for (const [key, template] of Object.entries(step.env)) {
  process.env[key] = template.replace(/\$\{\{\s*inputs\.([\w-]+)\s*\}\}/g, (_, name) => inputs[name]);
}
process.env.REPORT_PATH = input.reportPath;
const result = { failures: [], method: null, body: null };
const record = method => async args => { Object.assign(result, { method, ...args }); };
const github = { rest: { issues: {
  listComments: async () => ({ data: input.comments }),
  createComment: record('createComment'),
  updateComment: record('updateComment')
} } };
github.paginate = async (method, args) => (await method(args)).data;
const AsyncFunction = (async () => {}).constructor;

new AsyncFunction('require', 'context', 'github', 'core', step.with.script)(
  require, input.context, github, { setFailed: message => result.failures.push(message) }
).catch(error => result.failures.push(error.message))
  .then(() => process.stdout.write(JSON.stringify(result)));
