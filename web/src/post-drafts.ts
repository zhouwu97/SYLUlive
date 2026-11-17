import {captureAuthSession} from './api';
import type {MediaItem} from './media';

export type PostDraft = {
  title: string; content: string; postType: string; price: string; contactType: string; contact: string;
  files: File[]; existing: MediaItem[]; imagesChanged: boolean; uncertain: boolean;
};
const drafts = new Map<string, {value: PostDraft; isCurrent: () => boolean}>();
export function readPostDraft(key: string): PostDraft | undefined {
  for (const [id, draft] of drafts) if (!draft.isCurrent()) drafts.delete(id);
  return drafts.get(key)?.value;
}
export function savePostDraft(key: string, value: PostDraft) {
  drafts.set(key, {value, isCurrent: captureAuthSession()});
}
export function removePostDraft(key: string) {drafts.delete(key);}
export function clearPostDrafts() {drafts.clear();}
