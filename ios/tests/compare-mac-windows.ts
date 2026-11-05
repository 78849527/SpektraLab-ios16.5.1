// Original Mac Metal goldens vs Windows Tauri's shared CPU Layer2.
// The original Metal shader is bundled unchanged in iOS; these fixtures
// compare concrete algorithm output using ROMM rather than sRGB mid-grey.
import { readFileSync } from 'node:fs';
import { applyLayer2, decodeAdjustments } from '../../desktop/src/shared/adjustments';

interface Fixture {
  name: string;
  width: number;
  height: number;
  input: number[];
  output: number[];
  adjustments: unknown;
}
interface Golden {
  workingSpace: string;
  midGrey: number;
  fixtures: Fixture[];
}
const filepath = process.argv[2];
if (!filepath) throw new Error('Pass an original Metal GPU golden JSON path');
const data = JSON.parse(readFileSync(filepath, 'utf8')) as Golden;
if (data.workingSpace !== 'ROMM RGB' || Math.abs(data.midGrey - 0.3857) > 1e-6) {
  throw new Error('Invalid ProPhoto/ROMM working space or pivot');
}
let worst = 0;
const tolerance = 0.018; // 16-bit UNORM storage and GPU/CPU rounding
for (const sample of data.fixtures) {
  const pixels = sample.width * sample.height;
  if (sample.input.length !== pixels * 3 || sample.output.length !== pixels * 3) {
    throw new Error('Malformed Metal golden: ' + sample.name);
  }
  const cpu = new Float32Array(pixels * 4);
  for (let p = 0; p < pixels; p++) {
    cpu[p * 4] = sample.input[p * 3]!;
    cpu[p * 4 + 1] = sample.input[p * 3 + 1]!;
    cpu[p * 4 + 2] = sample.input[p * 3 + 2]!;
    cpu[p * 4 + 3] = 1;
  }
  const adjustments = decodeAdjustments(sample.adjustments);
  applyLayer2(cpu, sample.width, sample.height, adjustments, data.midGrey);
  let maximum = 0;
  let biggestPixel = -1;
  for (let p = 0; p < pixels; p++) {
    for (let k = 0; k < 3; k++) {
      const got = cpu[p * 4 + k]!;
      const expected = sample.output[p * 3 + k]!;
      const difference = Math.abs(got - expected);
      if (difference > maximum) {
        maximum = difference;
        biggestPixel = p;
      }
    }
  }
  worst = Math.max(worst, maximum);
  console.log(
    sample.name + ': max |Windows CPU - Mac Metal| = ' +
    maximum.toFixed(6) + ', pixel ' + biggestPixel
  );
  if (maximum > tolerance) {
    throw new Error(
      'Platform parity FAILED for ' + sample.name +
      ' (' + maximum + ' > ' + tolerance + ')'
    );
  }
}
if (data.fixtures.length < 7) {
  throw new Error('Expected at least seven original Metal comparison cases');
}
console.log(
  'WINDOWS_MAC_ROMM_PARITY_PASS: ' + data.fixtures.length +
  ' original Metal cases, worst channel delta ' + worst.toFixed(6)
);
