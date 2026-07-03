#!/usr/bin/env node

import { readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, '..');
const repoRoot = join(projectRoot, '..', '..');

const runtimeSource = readFileSync(join(repoRoot, 'src', 'runtime', 'bridge_responses.zig'), 'utf8');
const platformSource = readFileSync(join(repoRoot, 'src', 'platform', 'types.zig'), 'utf8');
const typeSource = readFileSync(join(projectRoot, 'zero-native.d.ts'), 'utf8');

const errors = [];

function addError(message) {
  errors.push(message);
}

function sliceBetween(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  if (start === -1) {
    addError(`missing marker: ${startMarker}`);
    return '';
  }

  const end = source.indexOf(endMarker, start);
  if (end === -1) {
    addError(`missing marker: ${endMarker}`);
    return '';
  }

  return source.slice(start, end);
}

function unique(values) {
  return [...new Set(values)];
}

function publicViewJsonKeys() {
  const body = sliceBetween(runtimeSource, 'fn writeViewJsonToWriter', 'fn writeOptionalRectJson');
  return unique([...body.matchAll(/\\\"([A-Za-z][A-Za-z0-9]*)\\\"/g)].map((match) => match[1]));
}

function viewInfoTypeBody() {
  return sliceBetween(typeSource, 'export interface ZeroNativeViewInfo', 'export type ZeroNativeNativeViewKind');
}

function interfaceHasProperty(body, key) {
  return new RegExp(`\\n\\s*${key}[?:]?\\s*:`).test(body);
}

function platformCursorTags() {
  const body = sliceBetween(platformSource, 'pub const Cursor = enum {', '};');
  return body
    .split('\n')
    .map((line) => line.trim().replace(/,$/, ''))
    .filter((line) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(line));
}

function platformEnumTags(enumName) {
  const body = sliceBetween(platformSource, `pub const ${enumName} = enum {`, '};');
  return body
    .split('\n')
    .map((line) => line.trim().replace(/,$/, ''))
    .filter((line) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(line));
}

function typeUnionTags(typeName) {
  const match = typeSource.match(new RegExp(`export type ${typeName} = ([^;]+);`));
  if (!match) {
    addError(`missing type union: ${typeName}`);
    return [];
  }

  return [...match[1].matchAll(/"([^"]+)"/g)].map((tag) => tag[1]);
}

const viewInfoBody = viewInfoTypeBody();
for (const key of publicViewJsonKeys()) {
  if (!interfaceHasProperty(viewInfoBody, key)) {
    addError(`ZeroNativeViewInfo is missing runtime field "${key}"`);
  }
}

const cursorTags = platformCursorTags();
const typeCursorTags = typeUnionTags('ZeroNativeCursor');
for (const tag of cursorTags) {
  if (!typeCursorTags.includes(tag)) {
    addError(`ZeroNativeCursor is missing platform cursor "${tag}"`);
  }
}
for (const tag of typeCursorTags) {
  if (!cursorTags.includes(tag)) {
    addError(`ZeroNativeCursor includes unknown platform cursor "${tag}"`);
  }
}

const profileRiskTags = platformEnumTags('CanvasFrameProfileRisk');
const typeProfileRiskTags = typeUnionTags('ZeroNativeCanvasFrameProfileRisk');
for (const tag of profileRiskTags) {
  if (!typeProfileRiskTags.includes(tag)) {
    addError(`ZeroNativeCanvasFrameProfileRisk is missing platform risk "${tag}"`);
  }
}
for (const tag of typeProfileRiskTags) {
  if (!profileRiskTags.includes(tag)) {
    addError(`ZeroNativeCanvasFrameProfileRisk includes unknown platform risk "${tag}"`);
  }
}

if (errors.length > 0) {
  console.error('Runtime TypeScript contract check failed.');
  for (const error of errors) {
    console.error(`  - ${error}`);
  }
  process.exit(1);
}

console.log('Runtime TypeScript contract is in sync.');
