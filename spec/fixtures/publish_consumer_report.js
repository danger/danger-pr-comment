const input = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
const job = input.workflow.jobs.comment;
const step = job.steps.at(-1);
const definition = (input.workflow.on || input.workflow.true).workflow_call.inputs;
const inputs = { ...Object.fromEntries(Object.entries(definition).map(([key, value]) => [key, value.default])), ...input.inputs };
function evaluate(expression) {
  const value = expression.replace(/\binputs\.([\w-]+)/g, 'inputs["$1"]');
  return new Function('inputs', 'github', `return (${value});`)(
    inputs, { event_name: input.context.eventName, event: input.context.payload }
  );
}
const result = { failures: [], notices: [], calls: [], skipped: false, method: null, body: null };

async function main() {
  if (!evaluate(job.if)) {
    result.skipped = true;
    return;
  }
  for (const [key, template] of Object.entries(step.env)) {
    process.env[key] = template.replace(/\$\{\{\s*(.*?)\s*\}\}/g, (_, expression) => evaluate(expression) ?? '');
  }
  process.env.REPORT_PATH = input.reportPath;
  const record = (method, data) => async args => {
    result.calls.push(method);
    if (method === 'createComment' || method === 'updateComment') Object.assign(result, { method, ...args });
    return { data };
  };
  const github = { rest: {
    pulls: {
      list: record('listPulls', [input.pr]),
      get: record('getPull', input.pr)
    },
    issues: {
      listComments: record('listComments', input.comments),
      createComment: record('createComment'),
      updateComment: record('updateComment')
    }
  } };
  github.paginate = async (method, args) => (await method(args)).data;
  const AsyncFunction = (async () => {}).constructor;
  await new AsyncFunction('require', 'context', 'github', 'core', step.with.script)(
    require, input.context, github, {
      setFailed: message => result.failures.push(message),
      notice: message => result.notices.push(message)
    }
  );
}

main().catch(error => result.failures.push(error.message))
  .then(() => process.stdout.write(JSON.stringify(result)));
