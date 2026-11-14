import { createServer } from 'node:http';

const port = Number(process.env.PORT ?? 3000);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error('PORT must be an integer from 1 to 65535.');
}

createServer((request, response) => {
  const isHealthCheck = request.method === 'GET' && request.url === '/health';
  response.writeHead(isHealthCheck ? 200 : 404, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  response.end(JSON.stringify(isHealthCheck ? { status: 'ok' } : { error: 'Not found' }));
}).listen(port, '0.0.0.0', () => {
  console.log(`Presentation Coach server listening on port ${port}`);
});

// Temporary deployment check. Log only the outcome, never API data or credentials.
if (process.env.RENDER === 'true') {
  try {
    const { default: OpenAI } = await import('openai');
    await new OpenAI({ maxRetries: 0, timeout: 10000 }).models.list();
    console.log('StageSight OpenAI check: accepted');
  } catch (error) {
    const status = Number.isInteger(error.status) ? error.status : 'no HTTP response';
    console.log(`StageSight OpenAI check: failed (${status})`);
  }
}
