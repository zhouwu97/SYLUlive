import {expect, it} from 'vitest';
import {inflateRawSync} from 'node:zlib';
import {storeArchive} from './store-archive.mjs';

it('商店 ZIP 排序可复现、manifest 在根目录且可解压', () => {
  const first = storeArchive({'relay.js':'// payload','manifest.json':'{"manifest_version":3}'});
  const second = storeArchive({'manifest.json':'{"manifest_version":3}','relay.js':'// payload'});
  expect(first.equals(second)).toBe(true);
  const length = first.readUInt16LE(26), size = first.readUInt32LE(18);
  expect(first.subarray(30,30+length).toString()).toBe('manifest.json');
  expect(inflateRawSync(first.subarray(30+length,30+length+size)).toString()).toBe('{"manifest_version":3}');
  expect(first.readUInt32LE(first.length-22)).toBe(0x06054b50);
  expect(first.readUInt16LE(first.length-12)).toBe(2);
});

it.each(['../secret','folder/file','/root','..','.'])('拒绝越界或无效条目 %s', name => {
  expect(()=>storeArchive({[name]:'payload'})).toThrow('Invalid store archive filename');
});
