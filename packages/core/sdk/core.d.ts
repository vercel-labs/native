export declare function asciiBytes(s: string): Uint8Array;
export declare function utf8Bytes(s: string): Uint8Array;
export type Msgish = {
    readonly kind: string;
};
import { type WindowDescriptor, type WindowDescriptorSpec } from "./events.js";
export declare function windowDescriptor(spec: WindowDescriptorSpec): WindowDescriptor;
/** Cooperative cancellation capability supplied by generated service hosts. */
export interface ServiceCancellation {
    /** True after Cmd.cancel or the operation deadline requests cancellation. */
    readonly cancelled: () => boolean;
    /** Throw a boundary-tagged cancellation error when cancellation was requested. */
    readonly throwIfCancelled: () => void;
}
export type TimestampKind<M extends Msgish> = M extends Msgish ? {
    [K in Exclude<keyof M, "kind">]-?: M[K] extends number ? [Exclude<keyof M, "kind">] extends [K] ? M["kind"] : never : never;
}[Exclude<keyof M, "kind">] : never;
export type BytesKind<M extends Msgish> = M extends Msgish ? {
    [K in Exclude<keyof M, "kind">]-?: M[K] extends Uint8Array ? [Exclude<keyof M, "kind">] extends [K] ? M["kind"] : never : never;
}[Exclude<keyof M, "kind">] : never;
export type ServiceKind<M extends Msgish, P> = M extends Msgish ? {
    [K in Exclude<keyof M, "kind">]-?: M[K] extends P ? P extends M[K] ? [Exclude<keyof M, "kind">] extends [K] ? M["kind"] : never : never : never;
}[Exclude<keyof M, "kind">] : never;
export interface ServiceRoute<M extends Msgish, P> {
    readonly key?: string;
    readonly ok: ServiceKind<M, P>;
    readonly err: BytesKind<M>;
}
export interface ServiceStreamRoute<M extends Msgish, P> extends ServiceRoute<M, P> {
    readonly channelKey: number;
    readonly event: ChannelEventKind<M>;
}
export type EmptyKind<M extends Msgish> = M extends Msgish ? [Exclude<keyof M, "kind">] extends [never] ? M["kind"] : never : never;
export type FetchedKind<M extends Msgish> = M extends Msgish ? {
    [K in Exclude<keyof M, "kind">]-?: M[K] extends Uint8Array ? Exclude<keyof M, "kind" | K> extends infer O ? O extends keyof M ? M[O] extends number ? [Exclude<keyof M, "kind" | K | O>] extends [never] ? M["kind"] : never : never : never : never : never;
}[Exclude<keyof M, "kind">] : never;
export interface EnvMsg<M extends Msgish> {
    readonly env: string;
    readonly msg: BytesKind<M>;
}
export type AudioState = "loaded" | "position" | "completed" | "failed" | "rejected" | "spectrum";
export type AudioEventArm = {
    readonly state: AudioState;
    readonly positionMs: number;
    readonly durationMs: number;
    readonly playing: boolean;
    readonly buffering: boolean;
    readonly bands: Uint8Array;
};
export type AudioEventKind<M extends Msgish> = M extends Msgish ? [Exclude<keyof M, "kind">] extends [keyof AudioEventArm] ? [keyof AudioEventArm] extends [Exclude<keyof M, "kind">] ? M extends Msgish & AudioEventArm ? [AudioState] extends [M["state"]] ? M["kind"] : never : never : never : never : never;
export type VideoState = "loaded" | "position" | "completed" | "failed" | "rejected";
export type VideoEventArm = {
    readonly state: VideoState;
    readonly positionMs: number;
    readonly durationMs: number;
    readonly playing: boolean;
    readonly buffering: boolean;
    readonly width: number;
    readonly height: number;
};
export type VideoEventKind<M extends Msgish> = M extends Msgish ? [Exclude<keyof M, "kind">] extends [keyof VideoEventArm] ? [keyof VideoEventArm] extends [Exclude<keyof M, "kind">] ? M extends Msgish & VideoEventArm ? [VideoState] extends [M["state"]] ? M["kind"] : never : never : never : never : never;
export type ImageState = "loaded" | "rejected" | "not_found" | "io_failed" | "connect_failed" | "tls_failed" | "protocol_failed" | "timed_out" | "http_status" | "cancelled" | "too_large" | "unsupported" | "decode_failed" | "registry_full" | "alloc_failed";
export type ImageEventArm = {
    readonly id: number;
    readonly state: ImageState;
    readonly width: number;
    readonly height: number;
    readonly status: number;
};
export type ImageEventKind<M extends Msgish> = M extends Msgish ? [Exclude<keyof M, "kind">] extends [keyof ImageEventArm] ? [keyof ImageEventArm] extends [Exclude<keyof M, "kind">] ? M extends Msgish & ImageEventArm ? [ImageState] extends [M["state"]] ? M["kind"] : never : never : never : never : never;
export type ChannelState = "data" | "closed" | "rejected";
export type ChannelEventArm = {
    readonly key: number;
    readonly state: ChannelState;
    readonly bytes: Uint8Array;
    readonly droppedPending: number;
    readonly droppedTotal: number;
};
export type ChannelEventKind<M extends Msgish> = M extends Msgish ? [Exclude<keyof M, "kind">] extends [keyof ChannelEventArm] ? [keyof ChannelEventArm] extends [Exclude<keyof M, "kind">] ? M extends Msgish & ChannelEventArm ? [ChannelState] extends [M["state"]] ? M["kind"] : never : never : never : never : never;
export interface ChannelRoute<M extends Msgish> {
    readonly event: ChannelEventKind<M>;
}
export type AudioCaptureSource = "microphone" | "system";
export type AudioCaptureState = "started" | "data" | "failed" | "stopped" | "rejected";
export type AudioCaptureSampleRate = 16000 | 24000 | 48000;
export type AudioCaptureChannels = 1 | 2;
export interface AudioCaptureSpec {
    readonly source: AudioCaptureSource;
    readonly sampleRate?: AudioCaptureSampleRate;
    readonly channels?: AudioCaptureChannels;
}
export type AudioCaptureEventArm = {
    readonly key: number;
    readonly state: AudioCaptureState;
    readonly source: AudioCaptureSource;
    readonly sampleRate: number;
    readonly channels: number;
    readonly timestampMs: number;
    readonly frames: number;
    readonly pcm: Uint8Array;
    readonly droppedPending: number;
    readonly droppedTotal: number;
};
export type AudioCaptureEventKind<M extends Msgish> = M extends Msgish ? [Exclude<keyof M, "kind">] extends [keyof AudioCaptureEventArm] ? [keyof AudioCaptureEventArm] extends [Exclude<keyof M, "kind">] ? M extends Msgish & AudioCaptureEventArm ? [AudioCaptureState] extends [M["state"]] ? [AudioCaptureSource] extends [M["source"]] ? M["kind"] : never : never : never : never : never : never;
export interface AudioCaptureRoute<M extends Msgish> {
    readonly event: AudioCaptureEventKind<M>;
}
export type PtyState = "output" | "exit";
export type PtyExitReason = "exited" | "signaled" | "cancelled" | "rejected" | "spawn_failed";
export type PtyEventArm = {
    readonly key: Uint8Array;
    readonly state: PtyState;
    readonly bytes: Uint8Array;
    readonly code: number;
    readonly reason: PtyExitReason;
    readonly signal: number;
    readonly droppedWrites: number;
};
export type PtyEventKind<M extends Msgish> = M extends Msgish ? [Exclude<keyof M, "kind">] extends [keyof PtyEventArm] ? [keyof PtyEventArm] extends [Exclude<keyof M, "kind">] ? M extends Msgish & PtyEventArm ? [PtyState] extends [M["state"]] ? [PtyExitReason] extends [M["reason"]] ? M["kind"] : never : never : never : never : never : never;
export interface PtyRoute<M extends Msgish> {
    readonly key?: string;
    readonly cols?: number;
    readonly rows?: number;
    readonly term?: string;
    readonly event: PtyEventKind<M>;
}
export type HostScalar = number | boolean | Uint8Array;
export type HostRecord = {
    readonly [field: string]: HostScalar;
};
export interface RequestRoute<M extends Msgish> {
    readonly key?: string;
    readonly ok: BytesKind<M>;
    readonly err: BytesKind<M>;
}
export interface WriteRoute<M extends Msgish> {
    readonly key?: string;
    readonly ok: EmptyKind<M>;
    readonly err: BytesKind<M>;
}
export interface FileReadStreamRoute<M extends Msgish> {
    readonly key?: string;
    readonly chunk: BytesKind<M>;
    readonly done: TimestampKind<M>;
    readonly err: BytesKind<M>;
}
export interface FileStatArm {
    readonly exists: boolean;
    readonly size: number;
    readonly mtimeMs: number;
}
export type FileStatKind<M extends Msgish> = M extends Msgish ? [Exclude<keyof M, "kind">] extends [keyof FileStatArm] ? [keyof FileStatArm] extends [Exclude<keyof M, "kind">] ? M extends Msgish & FileStatArm ? M["kind"] : never : never : never : never;
export interface FileStatRoute<M extends Msgish> {
    readonly key?: string;
    readonly ok: FileStatKind<M>;
    readonly err: BytesKind<M>;
}
export interface StoreScanOptions {
    readonly limit?: number;
    readonly after?: string | Uint8Array;
}
export interface DbText {
    readonly __dbText: true;
    readonly bytes: ReadonlyArray<number>;
}
export declare function dbText(bytes: Uint8Array): DbText;
export type DbValue = null | number | string | Uint8Array | boolean | DbText;
export type DbStatement = readonly [sql: string, params: ReadonlyArray<DbValue>];
export interface DbRowsRoute<M extends Msgish> {
    readonly key?: string;
    readonly page: BytesKind<M>;
    readonly done: EmptyKind<M>;
    readonly err: BytesKind<M>;
}
export interface TypedRowsRoute<Row, M extends Msgish> extends DbRowsRoute<M> {
    readonly __row?: Row;
}
export interface TypedDbStatement {
    readonly sql: string;
    readonly params: ReadonlyArray<DbValue>;
    readonly __typedDbStatement: true;
}
export interface FetchRoute<M extends Msgish> {
    readonly key?: string;
    readonly ok: FetchedKind<M>;
    readonly err: BytesKind<M>;
}
export interface FetchStreamRoute<M extends Msgish> {
    readonly key?: string;
    readonly line: BytesKind<M>;
    readonly ok: TimestampKind<M>;
    readonly err: BytesKind<M>;
}
export interface SpawnRoute<M extends Msgish> {
    readonly key?: string;
    readonly stdin?: Uint8Array;
    readonly line?: BytesKind<M>;
    readonly exit: TimestampKind<M>;
    readonly err: BytesKind<M>;
}
export interface SpawnCollectRoute<M extends Msgish> {
    readonly key?: string;
    readonly stdin?: Uint8Array;
    readonly collect: true;
    readonly exit: FetchedKind<M>;
    readonly err: BytesKind<M>;
}
export interface AudioSource {
    readonly path?: Uint8Array;
    readonly url?: Uint8Array;
    readonly cachePath?: Uint8Array;
    readonly expectedBytes?: number;
}
export interface AudioRoute<M extends Msgish> {
    readonly event: AudioEventKind<M>;
}
export interface VideoSource {
    readonly surface: number;
    readonly path?: Uint8Array;
    readonly url?: Uint8Array;
    readonly autoplay?: boolean;
    readonly loop?: boolean;
    readonly muted?: boolean;
}
export interface VideoRoute<M extends Msgish> {
    readonly event: VideoEventKind<M>;
}
export interface ImageSource {
    readonly path?: Uint8Array;
    readonly url?: Uint8Array;
    readonly cachePath?: Uint8Array;
    readonly expectedBytes?: number;
}
export interface ImageRoute<M extends Msgish> {
    readonly event: ImageEventKind<M>;
}
export type FetchMethod = "GET" | "POST" | "PUT" | "DELETE" | "PATCH" | "HEAD";
export interface FetchSpec {
    readonly url: Uint8Array;
    readonly method?: FetchMethod;
    readonly headers?: {
        readonly [name: string]: string | Uint8Array;
    };
    readonly body?: Uint8Array;
    readonly timeoutMs?: number;
}
export interface FetchStreamSpec extends FetchSpec {
    readonly maxLineBytes?: number;
}
export interface NotificationSpec {
    readonly id?: Uint8Array;
    readonly title: Uint8Array;
    readonly subtitle?: Uint8Array;
    readonly body?: Uint8Array;
    readonly actionLabel?: Uint8Array;
    readonly actionCommand?: Uint8Array;
}
export type LocalTimeStyle = "date" | "time" | "datetime";
export type Cmd<M extends Msgish> = {
    readonly op: "none";
} | {
    readonly op: "persist";
} | {
    readonly op: "now";
    readonly msgKind: string;
} | {
    readonly op: "host";
    readonly name: string;
    readonly args: readonly number[];
} | {
    readonly op: "host_bytes";
    readonly name: string;
    readonly payload: Uint8Array;
} | {
    readonly op: "request";
    readonly name: string;
    readonly key: string;
    readonly okKind: string;
    readonly errKind: string;
    readonly typedService: boolean;
    readonly payload: Uint8Array;
} | {
    readonly op: "service_stream_request";
    readonly name: string;
    readonly key: string;
    readonly okKind: string;
    readonly errKind: string;
    readonly typedService: true;
    readonly channelKey: number;
    readonly eventKind: string;
    readonly maxPending: number;
    readonly payload: Uint8Array;
} | {
    readonly op: "cancel";
    readonly key: string;
} | {
    readonly op: "read_file";
    readonly key: string;
    readonly okKind: string;
    readonly errKind: string;
    readonly path: Uint8Array;
} | {
    readonly op: "write_file";
    readonly key: string;
    readonly okKind: string;
    readonly errKind: string;
    readonly path: Uint8Array;
    readonly bytes: Uint8Array;
} | {
    readonly op: "append_file";
    readonly key: string;
    readonly okKind: string;
    readonly errKind: string;
    readonly path: Uint8Array;
    readonly bytes: Uint8Array;
} | {
    readonly op: "stat_file";
    readonly key: string;
    readonly okKind: string;
    readonly errKind: string;
    readonly path: Uint8Array;
} | {
    readonly op: "delete_file";
    readonly key: string;
    readonly okKind: string;
    readonly errKind: string;
    readonly path: Uint8Array;
} | {
    readonly op: "read_file_stream";
    readonly key: string;
    readonly chunkKind: string;
    readonly doneKind: string;
    readonly errKind: string;
    readonly path: Uint8Array;
} | {
    readonly op: "write_file_stream";
    readonly key: string;
    readonly okKind: string;
    readonly errKind: string;
    readonly path: Uint8Array;
} | {
    readonly op: "write_file_chunk";
    readonly key: string;
    readonly okKind: string;
    readonly errKind: string;
    readonly bytes: Uint8Array;
} | {
    readonly op: "write_file_close";
    readonly key: string;
    readonly okKind: string;
    readonly errKind: string;
} | {
    readonly op: "store_set";
    readonly key: string;
    readonly okKind: string;
    readonly errKind: string;
    readonly storeKey: string;
    readonly bytes: Uint8Array;
} | {
    readonly op: "store_get" | "store_delete";
    readonly key: string;
    readonly okKind: string;
    readonly errKind: string;
    readonly storeKey: string;
} | {
    readonly op: "store_scan";
    readonly key: string;
    readonly okKind: string;
    readonly errKind: string;
    readonly prefix: string;
    readonly limit: number;
    readonly after: string | Uint8Array;
} | {
    readonly op: "store_set_many";
    readonly key: string;
    readonly okKind: string;
    readonly errKind: string;
    readonly entries: ReadonlyArray<readonly [string, Uint8Array]>;
} | {
    readonly op: "db_query";
    readonly key: string;
    readonly pageKind: string;
    readonly doneKind: string;
    readonly errKind: string;
    readonly sql: string;
    readonly params: ReadonlyArray<DbValue>;
} | {
    readonly op: "db_exec";
    readonly key: string;
    readonly okKind: string;
    readonly errKind: string;
    readonly statements: ReadonlyArray<DbStatement>;
} | {
    readonly op: "fetch";
    readonly key: string;
    readonly okKind: string;
    readonly errKind: string;
    readonly method: FetchMethod;
    readonly timeoutMs: number;
    readonly url: Uint8Array;
    readonly headers: readonly {
        readonly name: string;
        readonly value: string | Uint8Array;
    }[];
    readonly body: Uint8Array;
} | {
    readonly op: "fetch_stream";
    readonly key: string;
    readonly lineKind: string;
    readonly okKind: string;
    readonly errKind: string;
    readonly method: FetchMethod;
    readonly timeoutMs: number;
    readonly maxLineBytes: number;
    readonly url: Uint8Array;
    readonly headers: readonly {
        readonly name: string;
        readonly value: string | Uint8Array;
    }[];
    readonly body: Uint8Array;
} | {
    readonly op: "clip_write";
    readonly bytes: Uint8Array;
} | {
    readonly op: "clip_read";
    readonly key: string;
    readonly okKind: string;
    readonly errKind: string;
} | {
    readonly op: "show_notification";
    readonly id: Uint8Array;
    readonly title: Uint8Array;
    readonly subtitle: Uint8Array;
    readonly body: Uint8Array;
    readonly actionLabel: Uint8Array;
    readonly actionCommand: Uint8Array;
} | {
    readonly op: "delay";
    readonly key: string;
    readonly afterMs: number;
    readonly msgKind: string;
} | {
    readonly op: "spawn";
    readonly key: string;
    readonly lineKind: string;
    readonly exitKind: string;
    readonly errKind: string;
    readonly collect: boolean;
    readonly argv: readonly Uint8Array[];
    readonly stdin: Uint8Array;
} | {
    readonly op: "audio_play";
    readonly key: string;
    readonly eventKind: string;
    readonly path: Uint8Array;
    readonly url: Uint8Array;
    readonly cachePath: Uint8Array;
    readonly expectedBytes: number;
} | {
    readonly op: "audio_ctl";
    readonly key: string;
    readonly verb: "pause" | "resume" | "stop" | "seek" | "volume";
    readonly value: number;
} | {
    readonly op: "video_load";
    readonly key: string;
    readonly eventKind: string;
    readonly surface: number;
    readonly path: Uint8Array;
    readonly url: Uint8Array;
    readonly autoplay: boolean;
    readonly loop: boolean;
    readonly muted: boolean;
} | {
    readonly op: "video_ctl";
    readonly key: string;
    readonly verb: "play" | "pause" | "stop" | "seek" | "volume" | "muted" | "loop";
    readonly value: number;
} | {
    readonly op: "window_show";
    readonly label: string;
} | {
    readonly op: "window_hide";
    readonly label: string;
} | {
    readonly op: "dock_presence";
    readonly visible: boolean;
} | {
    readonly op: "quit_app";
} | {
    readonly op: "image_load";
    readonly id: number;
    readonly eventKind: string;
    readonly path: Uint8Array;
    readonly url: Uint8Array;
    readonly cachePath: Uint8Array;
    readonly expectedBytes: number;
} | {
    readonly op: "image_cancel";
    readonly id: number;
} | {
    readonly op: "image_unregister";
    readonly id: number;
} | {
    readonly op: "channel_open";
    readonly key: number;
    readonly eventKind: string;
    readonly maxPending: number;
} | {
    readonly op: "channel_close";
    readonly key: number;
} | {
    readonly op: "audio_capture_start";
    readonly key: number;
    readonly source: AudioCaptureSource;
    readonly sampleRate: number;
    readonly channels: number;
    readonly eventKind: string;
} | {
    readonly op: "audio_capture_stop";
    readonly key: number;
} | {
    readonly op: "pty_spawn";
    readonly key: string;
    readonly eventKind: string;
    readonly cols: number;
    readonly rows: number;
    readonly term: string;
    readonly argv: readonly Uint8Array[];
} | {
    readonly op: "pty_write";
    readonly key: string;
    readonly bytes: Uint8Array;
} | {
    readonly op: "pty_resize";
    readonly key: string;
    readonly cols: number;
    readonly rows: number;
} | {
    readonly op: "pty_kill";
    readonly key: string;
} | {
    readonly op: "batch";
    readonly cmds: readonly Cmd<M>[];
};
export declare function hostRecordBytes(payload: HostRecord): Uint8Array;
export declare function serviceConcat(parts: readonly Uint8Array[]): Uint8Array;
export declare function serviceBoolBytes(value: boolean): Uint8Array;
export declare function serviceF64Bytes(value: number): Uint8Array;
export declare function serviceI64Bytes(value: number): Uint8Array;
export declare function serviceBytes(value: Uint8Array): Uint8Array;
export declare function serviceEnumBytes(index: number): Uint8Array;
export declare function serviceUnionBytes(index: number): Uint8Array;
export declare function serviceOptionalBytes(value: Uint8Array | null): Uint8Array;
export declare function serviceSliceBytes(values: readonly Uint8Array[]): Uint8Array;
declare function hostCmd(name: string, payload: Uint8Array | HostRecord): Cmd<never>;
declare function hostCmd(name: string, ...args: readonly number[]): Cmd<never>;
declare function fetchCmd<M extends Msgish>(spec: FetchSpec, route: FetchRoute<M>): Cmd<M>;
declare function fetchCmd<M extends Msgish>(spec: FetchStreamSpec, route: FetchStreamRoute<M>): Cmd<M>;
export declare const Cmd: {
    none: Cmd<never>;
    persist(): Cmd<never>;
    now<M extends Msgish>(msgKind: TimestampKind<M>): Cmd<M>;
    host: typeof hostCmd;
    request<M extends Msgish>(name: string, payload: Uint8Array | HostRecord, route: RequestRoute<M>): Cmd<M>;
    serviceRequest<M extends Msgish, P>(name: string, payload: Uint8Array, route: ServiceRoute<M, P>): Cmd<M>;
    serviceStreamRequest<M extends Msgish, P>(name: string, channelKey: number, payload: Uint8Array, route: ServiceStreamRoute<M, P>, maxPending: number): Cmd<M>;
    cancel(key: string): Cmd<never>;
    readFile<M extends Msgish>(path: Uint8Array, route: RequestRoute<M>): Cmd<M>;
    writeFile<M extends Msgish>(path: Uint8Array, bytes: Uint8Array, route: WriteRoute<M>): Cmd<M>;
    appendFile<M extends Msgish>(path: Uint8Array, bytes: Uint8Array, route: WriteRoute<M>): Cmd<M>;
    statFile<M extends Msgish>(path: Uint8Array, route: FileStatRoute<M>): Cmd<M>;
    deleteFile<M extends Msgish>(path: Uint8Array, route: WriteRoute<M>): Cmd<M>;
    readFileStream<M extends Msgish>(path: Uint8Array, route: FileReadStreamRoute<M>): Cmd<M>;
    writeFileStream<M extends Msgish>(key: string, path: Uint8Array, route: WriteRoute<M>): Cmd<M>;
    writeFileChunk<M extends Msgish>(key: string, bytes: Uint8Array, route: WriteRoute<M>): Cmd<M>;
    writeFileClose<M extends Msgish>(key: string, route: WriteRoute<M>): Cmd<M>;
    store: {
        set<M extends Msgish>(storeKey: string, bytes: Uint8Array, route: WriteRoute<M>): Cmd<M>;
        get<M extends Msgish>(storeKey: string, route: RequestRoute<M>): Cmd<M>;
        delete<M extends Msgish>(storeKey: string, route: WriteRoute<M>): Cmd<M>;
        scan<M extends Msgish>(prefix: string, options: StoreScanOptions, route: RequestRoute<M>): Cmd<M>;
        setMany<M extends Msgish>(entries: ReadonlyArray<readonly [string, Uint8Array]>, route: WriteRoute<M>): Cmd<M>;
    };
    credentials: {
        set<M extends Msgish>(credentialKey: string, secret: Uint8Array, route: WriteRoute<M>): Cmd<M>;
        get<M extends Msgish>(credentialKey: string, route: RequestRoute<M>): Cmd<M>;
        delete<M extends Msgish>(credentialKey: string, route: WriteRoute<M>): Cmd<M>;
    };
    db: {
        query<M extends Msgish>(sql: string, params: ReadonlyArray<DbValue>, route: DbRowsRoute<M>): Cmd<M>;
        exec<M extends Msgish>(statements: ReadonlyArray<DbStatement>, route: WriteRoute<M>): Cmd<M>;
    };
    fetch: typeof fetchCmd;
    clipboardWrite(bytes: Uint8Array): Cmd<never>;
    clipboardRead<M extends Msgish>(route: RequestRoute<M>): Cmd<M>;
    showNotification(spec: NotificationSpec): Cmd<never>;
    openExternalUrl(url: Uint8Array): Cmd<never>;
    revealPath(path: Uint8Array): Cmd<never>;
    formatLocalTime<M extends Msgish>(timestampMs: number, style: LocalTimeStyle, route: RequestRoute<M>): Cmd<M>;
    delay<M extends Msgish>(key: string, ms: number, msgKind: TimestampKind<M>): Cmd<M>;
    spawn<M extends Msgish>(argv: readonly Uint8Array[], route: SpawnRoute<M> | SpawnCollectRoute<M>): Cmd<M>;
    audioPlay<M extends Msgish>(key: string, source: AudioSource, route: AudioRoute<M>): Cmd<M>;
    audioPause(key: string): Cmd<never>;
    audioResume(key: string): Cmd<never>;
    audioStop(key: string): Cmd<never>;
    audioSeek(key: string, ms: number): Cmd<never>;
    audioSetVolume(key: string, volume: number): Cmd<never>;
    videoLoad<M extends Msgish>(key: string, source: VideoSource, route: VideoRoute<M>): Cmd<M>;
    videoPlay(key: string): Cmd<never>;
    videoPause(key: string): Cmd<never>;
    videoStop(key: string): Cmd<never>;
    videoSeek(key: string, ms: number): Cmd<never>;
    videoSetVolume(key: string, volume: number): Cmd<never>;
    videoSetMuted(key: string, muted: boolean): Cmd<never>;
    videoSetLoop(key: string, loop: boolean): Cmd<never>;
    showWindow(label: string): Cmd<never>;
    hideWindow(label: string): Cmd<never>;
    setDockPresence(visible: boolean): Cmd<never>;
    launchAtLoginStatus<M extends Msgish>(route: RequestRoute<M>): Cmd<M>;
    setLaunchAtLogin<M extends Msgish>(enabled: boolean, route: RequestRoute<M>): Cmd<M>;
    quitApp(): Cmd<never>;
    imageLoad<M extends Msgish>(id: number, source: ImageSource, route: ImageRoute<M>): Cmd<M>;
    imageCancel(id: number): Cmd<never>;
    imageUnregister(id: number): Cmd<never>;
    channelOpen<M extends Msgish>(key: number, route: ChannelRoute<M>): Cmd<M>;
    channelClose(key: number): Cmd<never>;
    audioCaptureStart<M extends Msgish>(key: number, spec: AudioCaptureSpec, route: AudioCaptureRoute<M>): Cmd<M>;
    audioCaptureStop(key: number): Cmd<never>;
    ptySpawn<M extends Msgish>(argv: readonly Uint8Array[], route: PtyRoute<M>): Cmd<M>;
    ptyWrite(key: string, bytes: Uint8Array): Cmd<never>;
    ptyResize(key: string, cols: number, rows: number): Cmd<never>;
    ptyKill(key: string): Cmd<never>;
    batch<M extends Msgish>(cmds: readonly Cmd<M>[]): Cmd<M>;
};
export type Sub<M extends Msgish> = {
    readonly op: "none";
} | {
    readonly op: "timer";
    readonly key: string;
    readonly everyMs: number;
    readonly msgKind: string;
} | {
    readonly op: "db_live";
    readonly key: string;
    readonly pageKind: string;
    readonly doneKind: string;
    readonly errKind: string;
    readonly sql: string;
    readonly params: ReadonlyArray<DbValue>;
    readonly tables: readonly string[];
} | {
    readonly op: "batch";
    readonly subs: readonly Sub<M>[];
};
export declare const Sub: {
    none: Sub<never>;
    timer<M extends Msgish>(key: string, everyMs: number, msgKind: TimestampKind<M>): Sub<M>;
    batch<M extends Msgish>(subs: readonly Sub<M>[]): Sub<M>;
};
export {};
