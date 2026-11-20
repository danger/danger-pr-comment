const input = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
const github = { event: input.event };
const format = (template, value) => template.replace('{0}', value);
const render = template => template.replace(/\$\{\{\s*(.*?)\s*\}\}/g, (_, expression) => {
  // GitHub treats absent nested context properties as empty strings.
  const value = expression.replace(/\bgithub\.event(?:\.[a-z_]\w*)+/gi, path => path.replace(/\./g, '?.'))
    .replace(/\binputs\.([\w-]+)/g, 'inputs["$1"]');
  return new Function('github', 'inputs', 'format', `return (${value});`)(github, input.inputs, format) ?? '';
});
process.stdout.write(JSON.stringify({
  run: render(input.run),
  environment: Object.fromEntries(Object.entries(input.environment).map(([key, value]) => [key, render(value)]))
}));
