// Tiny live diagnostic. Uses synthetic text only and never prints secrets.
require('./env.cjs').loadPrivateEnv();
async function main() {
  if (!process.env.OPENAI_API_KEY) throw Error('No server API key configured.');
  const response = await fetch('https://api.openai.com/v1/responses', {
    method: 'POST', signal: AbortSignal.timeout(60000),
    headers: { Authorization: 'Bearer ' + process.env.OPENAI_API_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: process.env.OPENAI_REPORT_MODEL || 'gpt-5.6-terra', store: false, max_output_tokens: 100, input: 'Reply with only: connection verified' })
  });
  const data = await response.json();
  if (!response.ok) {
    console.log(JSON.stringify({ success: false, http_status: response.status, error_type: data.error?.type, error_code: data.error?.code }));
    process.exitCode = 1; return;
  }
  console.log(JSON.stringify({ success: data.status === 'completed', http_status: response.status, model: data.model, status: data.status }));
  if (process.argv[2]) {
    const audio = require('node:fs').readFileSync(process.argv[2]);
    const form = new FormData();
    form.append('file', new Blob([audio], {type:'audio/wav'}), 'synthetic-test.wav');
    form.append('model', process.env.OPENAI_TRANSCRIBE_MODEL || 'gpt-transcribe');
    const stt = await fetch('https://api.openai.com/v1/audio/transcriptions', {method:'POST', signal:AbortSignal.timeout(60000), headers:{Authorization:'Bearer '+process.env.OPENAI_API_KEY}, body:form});
    const transcription = await stt.json();
    console.log(JSON.stringify({feature:'transcription',success:stt.ok && Boolean(transcription.text?.trim()),http_status:stt.status,error_code:transcription.error?.code,words:transcription.text?.trim().split(/\s+/).length}));
    if(!stt.ok)process.exitCode=1;
  }
}
main().catch(error => { console.log(JSON.stringify({success:false,error_class:'transport',code:error.cause?.code||error.code||error.name})); process.exitCode = 1; });
