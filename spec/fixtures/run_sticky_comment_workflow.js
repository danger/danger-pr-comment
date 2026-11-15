const input = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
const result = { calls: [], failures: [], comments: input.comments };
const bot = { login: 'github-actions[bot]', type: 'Bot' };
const githubContext = {
  repository: `${input.context.repo.owner}/${input.context.repo.repo}`,
  event: input.context.payload
};

function resolveTemplate(template) {
  return template.replace(/\$\{\{\s*(.*?)\s*\}\}/g, (_, expression) => {
    const value = expression.replace(/\binputs\.([\w-]+)/g, 'inputs["$1"]');
    return new Function('inputs', 'github', `return (${value});`)(input.inputs, githubContext);
  });
}

for (const [key, template] of Object.entries(input.environment)) {
  process.env[key] = resolveTemplate(template);
}
result.concurrencyGroup = resolveTemplate(input.concurrency.group);
result.cancelInProgress = input.concurrency['cancel-in-progress'];

const issues = {
  listComments: async args => {
    result.calls.push({ method: 'listComments', ...args });
    const offset = ((args.page || 1) - 1) * args.per_page;
    return { data: result.comments.slice(offset, offset + args.per_page) };
  },
  createComment: async args => {
    result.calls.push({ method: 'createComment', ...args });
    result.comments.push({ id: 1000, user: bot, body: args.body });
  },
  updateComment: async args => {
    result.calls.push({ method: 'updateComment', ...args });
    result.comments.find(comment => comment.id === args.comment_id).body = args.body;
  }
};
const github = {
  rest: { issues },
  paginate: async (method, args) => {
    const comments = [];
    for (let page = 1; ; page++) {
      const { data } = await method({ ...args, page });
      comments.push(...data);
      if (data.length < args.per_page) return comments;
    }
  }
};
const fs = { existsSync: () => true, readFileSync: () => JSON.stringify(input.report) };
const AsyncFunction = (async () => {}).constructor;

new AsyncFunction('require', 'context', 'github', 'core', input.script)(
  name => { if (name === 'fs') return fs; throw new Error(`Unexpected module: ${name}`); },
  input.context, github, { setFailed: message => result.failures.push(message) }
).catch(error => result.failures.push(error.message))
  .then(() => process.stdout.write(JSON.stringify(result)));
