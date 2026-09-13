// Tdarr "Custom JS Function" body for the Shrink Oversized Video flow.
// Pasted verbatim into the flow by scripts/tdarr-shrink-flow.py.
//
// Runs after Execute. Hands the encode and the library original to
// restore-dynamic-hdr.sh, which re-injects Dolby Vision and HDR10+.
// Output 1: continue (restored, or nothing needed restoring).
// Output 2: restore was needed and failed. The flow fails rather than
// swapping a Dolby Vision original for an HDR10-only copy.
module.exports = async (args) => {
  const { spawn } = require('child_process');
  const fs = require('fs');
  const path = require('path');

  const enc = args.inputFileObj._id;
  const src = args.originalLibraryFile._id;
  // Same basename as the encode: Replace Original File names the result
  // after the working file.
  const outDir = path.join(path.dirname(enc), 'dynhdr');
  fs.mkdirSync(outDir, { recursive: true });
  const out = path.join(outDir, path.basename(enc));

  const code = await new Promise((resolve) => {
    const p = spawn('bash', ['/opt/shrink/restore-dynamic-hdr.sh', src, enc, out]);
    const log = (d) => String(d).split('\n').filter(Boolean).forEach((l) => args.jobLog(`restore: ${l}`));
    p.stdout.on('data', log);
    p.stderr.on('data', log);
    p.on('error', (e) => { args.jobLog(`restore: ${e}`); resolve(1); });
    p.on('close', resolve);
  });

  if (code === 0) return { outputFileObj: { _id: out }, outputNumber: 1, variables: args.variables };
  if (code === 3) return { outputFileObj: args.inputFileObj, outputNumber: 1, variables: args.variables };
  return { outputFileObj: args.inputFileObj, outputNumber: 2, variables: args.variables };
};
