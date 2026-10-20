import { readFileSync } from 'node:fs';
import { importPackage } from '../_build/sdk/qti-score/index.mjs';

// Run python tools/project.py build-sdk first.
const bundle = importPackage(readFileSync(new URL('../web/sample-package.zip', import.meta.url)));
try {
  console.log(JSON.stringify(bundle.describe(), null, 2));
  const attempts = readFileSync(new URL('./package-attempts.jsonl', import.meta.url), 'utf8');
  const evaluation = bundle.scoreAttempts(attempts);
  console.log(JSON.stringify(evaluation.report, null, 2));
  console.log(evaluation.csv);
  const item = bundle.getItem('measurement');
  try { console.log(item.explain({ RESPONSE: 100.5 })); }
  finally { item.dispose(); }
} finally { bundle.dispose(); }
