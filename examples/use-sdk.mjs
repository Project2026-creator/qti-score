import { readFileSync } from 'node:fs';
import { compileItem } from '../_build/sdk/qti-score/index.mjs';

const xml = readFileSync(new URL('./numeric.xml', import.meta.url), 'utf8');
const item = compileItem(xml);
try {
  const attempts = [{ RESPONSE: 100 }, { RESPONSE: 100.5 }, { RESPONSE: 104 },
    { RESPONSE: 'not a number' }, { RESPONSE: 110 }, {}];
  console.log(JSON.stringify({
    item: item.describe(),
    attempts: item.scoreBatch(attempts),
    explanation: item.explain({ RESPONSE: 100.5 }),
  }, null, 2));
} finally {
  item.dispose();
}
