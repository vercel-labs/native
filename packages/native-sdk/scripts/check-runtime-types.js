#!/usr/bin/env node

import { readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, '..');
const repoRoot = join(projectRoot, '..', '..');

const runtimeSource = readFileSync(join(repoRoot, 'src', 'runtime', 'bridge_responses.zig'), 'utf8');
const platformSource = readFileSync(join(repoRoot, 'src', 'platform', 'types.zig'), 'utf8');
const bridgePayloadSource = readFileSync(join(repoRoot, 'src', 'runtime', 'bridge_payload.zig'), 'utf8');
const typeSource = readFileSync(join(projectRoot, 'native-sdk.d.ts'), 'utf8');

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
  return sliceBetween(typeSource, 'export interface NativeSdkViewInfo', 'export type NativeSdkNativeViewKind');
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
  const match = typeSource.match(new RegExp(`export type ${typeName} =\\s*([^;]+);`));
  if (!match) {
    addError(`missing type union: ${typeName}`);
    return [];
  }

  return [...match[1].matchAll(/"([^"]+)"/g)].map((tag) => tag[1]);
}

function checkSameTags(typeName, expectedTags, subject) {
  const actualTags = typeUnionTags(typeName);
  for (const tag of expectedTags) {
    if (!actualTags.includes(tag)) {
      addError(`${typeName} is missing ${subject} "${tag}"`);
    }
  }
  for (const tag of actualTags) {
    if (!expectedTags.includes(tag)) {
      addError(`${typeName} includes unknown ${subject} "${tag}"`);
    }
  }
}

const viewInfoBody = viewInfoTypeBody();
for (const key of publicViewJsonKeys()) {
  if (!interfaceHasProperty(viewInfoBody, key)) {
    addError(`NativeSdkViewInfo is missing runtime field "${key}"`);
  }
}

const cursorTags = platformCursorTags();
const typeCursorTags = typeUnionTags('NativeSdkCursor');
for (const tag of cursorTags) {
  if (!typeCursorTags.includes(tag)) {
    addError(`NativeSdkCursor is missing platform cursor "${tag}"`);
  }
}
for (const tag of typeCursorTags) {
  if (!cursorTags.includes(tag)) {
    addError(`NativeSdkCursor includes unknown platform cursor "${tag}"`);
  }
}

// The bridge's camelCase alias table capitalizes "webview" as "WebView"
// (mainWebView, childWebViews); every other segment follows plain
// first-letter capitalization. Deriving the same spellings here keeps the
// check pinned to the aliases JavaScript callers actually send.
const camelSegmentSpellings = new Map([
  ['webview', 'WebView'],
  ['webviews', 'WebViews'],
]);

function camelPlatformFeature(tag) {
  const [head, ...rest] = tag.split('_');
  return (
    head +
    rest
      .map((segment) => camelSegmentSpellings.get(segment) ?? segment[0].toUpperCase() + segment.slice(1))
      .join('')
  );
}

// The manual alias entries inside platformFeatureFromString: snake_case
// spellings resolve through comptime enum reflection, so the table only
// needs to hold the camelCase forms.
function bridgePlatformFeatureAliases() {
  const body = sliceBetween(bridgePayloadSource, 'pub fn platformFeatureFromString', '\n}');
  const aliases = new Map();
  for (const match of body.matchAll(/std\.mem\.eql\(u8, value, "([^"]+)"\)\) return \.([A-Za-z0-9_]+);/g)) {
    aliases.set(match[1], match[2]);
  }
  return aliases;
}

const featureTags = platformEnumTags('PlatformFeature');
const expectedFeatureUnion = featureTags.flatMap((tag) => {
  const camel = camelPlatformFeature(tag);
  return camel === tag ? [tag] : [tag, camel];
});
const typeFeatureTags = typeUnionTags('NativeSdkPlatformFeature');
for (const tag of expectedFeatureUnion) {
  if (!typeFeatureTags.includes(tag)) {
    addError(`NativeSdkPlatformFeature is missing platform feature "${tag}"`);
  }
}
for (const tag of typeFeatureTags) {
  if (!expectedFeatureUnion.includes(tag)) {
    addError(`NativeSdkPlatformFeature includes unknown platform feature "${tag}"`);
  }
}

const bridgeFeatureAliases = bridgePlatformFeatureAliases();
for (const tag of featureTags) {
  const camel = camelPlatformFeature(tag);
  if (camel === tag) continue;
  const target = bridgeFeatureAliases.get(camel);
  if (target === undefined) {
    addError(`bridge_payload.zig platformFeatureFromString is missing alias "${camel}" -> ${tag}`);
  } else if (target !== tag) {
    addError(`bridge_payload.zig platformFeatureFromString maps alias "${camel}" to ${target}, expected ${tag}`);
  }
}
for (const [camel, target] of bridgeFeatureAliases) {
  if (!featureTags.includes(target) || camelPlatformFeature(target) !== camel) {
    addError(`bridge_payload.zig platformFeatureFromString includes unknown alias "${camel}" -> ${target}`);
  }
}

const profileRiskTags = platformEnumTags('CanvasFrameProfileRisk');
const typeProfileRiskTags = typeUnionTags('NativeSdkCanvasFrameProfileRisk');
for (const tag of profileRiskTags) {
  if (!typeProfileRiskTags.includes(tag)) {
    addError(`NativeSdkCanvasFrameProfileRisk is missing platform risk "${tag}"`);
  }
}
for (const tag of typeProfileRiskTags) {
  if (!profileRiskTags.includes(tag)) {
    addError(`NativeSdkCanvasFrameProfileRisk includes unknown platform risk "${tag}"`);
  }
}

// A GPU surface reports the concrete backend that presented its frame, but
// callers request only the portable backends admitted by GpuSurfaceOptions.
// Keep those roles separate so adding a host renderer cannot silently make it
// appear as a valid create option in the public TypeScript API.
const backendTags = platformEnumTags('GpuSurfaceBackend');
checkSameTags('NativeSdkGpuSurfaceBackend', backendTags, 'reported GPU surface backend');

const supportedOptionsBody = sliceBetween(
  platformSource,
  'pub fn isSupported(self: GpuSurfaceOptions) bool {',
  '\n    }',
);
const requestBackendTags = unique(
  [...supportedOptionsBody.matchAll(/self\.backend == \.([A-Za-z_][A-Za-z0-9_]*)/g)].map((match) => match[1]),
);
checkSameTags('NativeSdkGpuSurfaceBackendRequest', requestBackendTags, 'requestable GPU surface backend');

if (!interfaceHasProperty(viewInfoBody, 'gpuBackend') ||
    !/\n\s*gpuBackend\s*:\s*NativeSdkGpuSurfaceBackend\s*;/.test(viewInfoBody)) {
  addError('NativeSdkViewInfo.gpuBackend must use the reported NativeSdkGpuSurfaceBackend type');
}

const createNativeViewBody = sliceBetween(
  typeSource,
  'export interface NativeSdkCreateNativeViewOptions',
  'export interface NativeSdkCreateWebViewViewOptions',
);
if (!/\n\s*gpuBackend\?\s*:\s*NativeSdkGpuSurfaceBackendRequest\s*;/.test(createNativeViewBody)) {
  addError('NativeSdkCreateNativeViewOptions.gpuBackend must use NativeSdkGpuSurfaceBackendRequest');
}

if (errors.length > 0) {
  console.error('Runtime TypeScript contract check failed.');
  for (const error of errors) {
    console.error(`  - ${error}`);
  }
  process.exit(1);
}

console.log('Runtime TypeScript contract is in sync.');
