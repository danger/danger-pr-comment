const input = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
const result = { calls: [], failures: [], notices: [], skipped: false };
const githubContext = { event_name: input.context.eventName, event: input.context.payload };

function evaluate(expression) {
  const value = expression.replace(/\binputs\.([\w-]+)/g, 'inputs["$1"]');
  return new Function('inputs', 'github', `return (${value});`)(input.inputs, githubContext);
}

async function main() {
  if (!evaluate(input.condition)) {
    result.skipped = true;
    return;
  }
  for (const [key, template] of Object.entries(input.environment)) {
    process.env[key] = template.replace(/\$\{\{\s*(.*?)\s*\}\}/g, (_, expression) => evaluate(expression) ?? '');
  }
  const record = (method, response) => async args => {
    result.calls.push({ method, ...args });
    if (input.apiError === method || (method === 'listPulls' && args.page === input.failPage)) {
      throw new Error('GitHub API unavailable');
    }
    return { data: typeof response === 'function' ? response(args) : response };
  };
  const page = (items, args) => {
    const offset = (args.page - 1) * args.per_page;
    return items.slice(offset, offset + args.per_page);
  };
  const github = { rest: {
    pulls: {
      list: record('listPulls', args => page(input.pulls, args)),
      get: record('getPull', input.pr)
    },
    issues: {
      listComments: record('listComments', args => page(input.comments, args)),
      createComment: record('createComment'),
      updateComment: record('updateComment')
    }
  } };
  github.paginate = async (method, args) => {
    const items = [];
    for (let page = 1; ; page++) {
      const { data } = await method({ ...args, page });
      items.push(...data);
      if (data.length < args.per_page) return items;
    }
  };
  const fs = { existsSync: () => true, readFileSync: () => JSON.stringify(input.report) };
  const AsyncFunction = (async () => {}).constructor;
  await new AsyncFunction('require', 'context', 'github', 'core', input.script)(
    name => { if (name === 'fs') return fs; throw new Error(`Unexpected module: ${name}`); },
    input.context, github, {
      setFailed: message => result.failures.push(message),
      notice: message => result.notices.push(message)
    }
  );
}

main().catch(error => result.failures.push(error.message))
  .then(() => process.stdout.write(JSON.stringify(result)));
