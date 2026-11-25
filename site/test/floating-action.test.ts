import assert from 'node:assert/strict';
import test from 'node:test';
import { hideWhileVisible } from '../src/lib/floating-action.ts';

type Entry = { target: Element; isIntersecting: boolean };

test('hides while any download action is visible and returns afterwards', () => {
  let notify: (entries: Entry[]) => void = () => {};
  const observed: Element[] = [];
  class FakeObserver {
    constructor(callback: (entries: Entry[]) => void) {
      notify = callback;
    }
    observe(target: Element) {
      observed.push(target);
    }
  }
  const action = { dataset: {} as Record<string, string> };
  const hero = {} as Element;
  const download = {} as Element;
  hideWhileVisible(action as unknown as HTMLElement, [hero, download], FakeObserver);
  assert.deepEqual(observed, [hero, download]);

  notify([{ target: hero, isIntersecting: true }, { target: download, isIntersecting: false }]);
  assert.equal(action.dataset.hidden, 'true');
  notify([{ target: hero, isIntersecting: false }]);
  assert.equal(action.dataset.hidden, 'false');
  notify([{ target: download, isIntersecting: true }]);
  assert.equal(action.dataset.hidden, 'true');
});

test('leaves the action alone on pages without download actions', () => {
  const action = { dataset: {} as Record<string, string> };
  hideWhileVisible(action as unknown as HTMLElement, []);
  hideWhileVisible(null, [{} as Element]);
  assert.deepEqual(action.dataset, {});
});

test('shows the action when visibility cannot be observed', () => {
  const action = { dataset: {} as Record<string, string> };
  hideWhileVisible(action as unknown as HTMLElement, [{} as Element], undefined);
  assert.equal(action.dataset.hidden, 'false');
});
