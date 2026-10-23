"""Run with the local OCR virtual environment's Python."""
import base64
from pathlib import Path
import unittest
import tempfile
import threading
import time
import json
from concurrent.futures import Future
from types import SimpleNamespace

import cv2
import numpy as np

source = Path(__file__).resolve().parents[1] / 'Resources/ocr_worker.py'
worker = {'__name__': 'worker_test'}
exec(compile(source.read_text(), str(source), 'exec'), worker)
replacement_patch = worker['replacement_patch']


def decode(value):
    return cv2.imdecode(np.frombuffer(base64.b64decode(value), np.uint8), cv2.IMREAD_UNCHANGED)


class UncertainFragmentTests(unittest.TestCase):
    def run_reading(self, original, retry='未確認', budget=4):
        image = np.full((40, 100, 3), 255, np.uint8)
        hint = {'text': '文化祭', 'confidence': .4, 'box': [10, 5, 80, 30]}
        calls = []
        previous = worker['recognize_crops']
        worker['recognize_crops'] = lambda ocr, crops: calls.append(crops[0].shape) or [retry]
        try:
            with tempfile.TemporaryDirectory() as folder:
                remaining = [budget]
                result = worker['confirm_fragments'](None, image, [0, 0, 100, 40], '文化祭の準備', original,
                    [hint], Path(folder), remaining)
                return result, calls, remaining
        finally:
            worker['recognize_crops'] = previous

    def test_independent_agreement_clears_low_confidence_without_another_decode(self):
        result, calls, remaining = self.run_reading('文化祭の準備')
        self.assertEqual((result, calls, remaining), ([], [], [4]))

    def test_only_the_doubtful_line_is_retried(self):
        result, calls, remaining = self.run_reading('文代祭の準備', retry='文化祭')
        self.assertEqual((result, calls, remaining), ([], [(25, 70, 3)], [3]))

    def test_disagreement_and_budget_exhaustion_keep_uncertainty(self):
        self.assertEqual(self.run_reading('文代祭')[0], ['文化祭'])
        result, calls, remaining = self.run_reading('文代祭', retry='文化祭', budget=0)
        self.assertEqual((result, calls, remaining), (['文化祭'], [], [0]))

    def reconcile(self, text='揖川先生！？', retry='指川先生', confidence=.99, budget=4, shape=(100, 40)):
        image = np.full((*shape, 3), 255, np.uint8)
        hint = {'text': '指川先生', 'confidence': confidence, 'box': [5, 5, shape[1]-5, shape[0]-5]}
        calls, previous = [], worker['recognize_crops']
        worker['recognize_crops'] = lambda ocr, crops: calls.append(crops[0].shape) or [retry]
        try:
            with tempfile.TemporaryDirectory() as folder:
                remaining = [budget]
                result = worker['reconcile_fragments'](None, image, [0, 0, shape[1], shape[0]], text,
                    [hint], Path(folder), remaining)
                return result, calls, remaining
        finally:
            worker['recognize_crops'] = previous

    def test_vertical_and_horizontal_local_agreement_correct_only_disputed_glyph(self):
        for shape in [(100, 40), (40, 100)]:
            result, calls, budget = self.reconcile(shape=shape)
            self.assertEqual(result, ('指川先生！？', []))
            self.assertEqual(calls, [(shape[0]-10, shape[1]-10, 3)])
            self.assertEqual(budget, [3])

    def test_strong_hint_does_not_override_confirmed_original_or_guess_a_third_reading(self):
        self.assertEqual(self.reconcile(retry='揖川先生')[0], ('揖川先生！？', []))
        self.assertEqual(self.reconcile(retry='梶川先生')[0], ('揖川先生！？', ['揖川先生']))

    def test_matching_weak_ambiguous_and_over_budget_hints_do_not_redecode(self):
        for arguments in [dict(text='指川先生！？'), dict(confidence=.9), dict(budget=0),
                          dict(text='揖川先生と梶川先生'), dict(text='まったく違う話です')]:
            self.assertEqual(self.reconcile(**arguments)[1], [])


class TextHandoffTests(unittest.TestCase):
    @staticmethod
    def block(identifier='b1'):
        return {'id': identifier, 'text': 'おはよう', 'textStyle': None,
                'bounds': {'x': 0, 'y': 0, 'width': 100, 'height': 100}}

    def test_text_is_available_before_repairs_and_final_retains_identical_ids(self):
        with tempfile.TemporaryDirectory() as folder:
            directory, pending = Path(folder), Future()
            task = threading.Thread(target=worker['finish_page'], args=(directory,
                [self.block()], 2, {'b1': pending}, time.monotonic()))
            task.start()
            deadline = time.monotonic()+1
            while not (directory / 'text.json').exists() and time.monotonic() < deadline:
                time.sleep(.005)
            draft = json.loads((directory / 'text.json').read_text())
            self.assertTrue(task.is_alive())
            self.assertEqual(draft['skippedCount'], 2)
            self.assertFalse(draft['blocks'][0]['replacementAllowed'])
            self.assertIsNone(draft['blocks'][0]['replacementPNG'])
            pending.set_result('verified-patch')
            task.join(1)
            final = json.loads((directory / 'state.json').read_text())
            self.assertEqual(final['phase'], 'done')
            self.assertEqual([b['id'] for b in final['page']['blocks']], [b['id'] for b in draft['blocks']])
            self.assertEqual(final['page']['blocks'][0]['replacementPNG'], 'verified-patch')
            self.assertEqual(json.loads((directory / 'text.json').read_text()), draft)

    def test_cancel_during_repair_does_not_wait_for_future_or_publish_done(self):
        with tempfile.TemporaryDirectory() as folder:
            directory, pending = Path(folder), Future()
            task = threading.Thread(target=worker['finish_page'], args=(directory,
                [self.block()], 0, {'b1': pending}, time.monotonic()))
            task.start()
            deadline = time.monotonic()+1
            while not (directory / 'text.json').exists() and time.monotonic() < deadline:
                time.sleep(.005)
            (directory / 'cancel').touch()
            task.join(.5)
            self.assertFalse(task.is_alive())
            self.assertEqual(json.loads((directory / 'state.json').read_text())['phase'], 'cancelled')
            self.assertFalse(pending.done())

    def test_finished_closed_patch_is_ready_while_open_background_is_pending(self):
        with tempfile.TemporaryDirectory() as folder:
            directory, ready, pending, open_ready = Path(folder), Future(), Future(), Future()
            ready.set_result('verified-closed-png'); open_ready.set_result('verified-open-png')
            closed = self.block()
            other = dict(self.block('b2'), text='こんにちは')
            opened = dict(self.block('b3'), text='ざわざわ', textStyle='outlinedDark')
            task = threading.Thread(target=worker['finish_page'], args=(directory,
                [closed, other, opened], 1, {'b1': ready, 'b2': pending, 'b3': open_ready}, time.monotonic()))
            task.start()
            deadline = time.monotonic()+1
            while not (directory / 'text.json').exists() and time.monotonic() < deadline:
                time.sleep(.005)
            draft = json.loads((directory / 'text.json').read_text())
            self.assertTrue(task.is_alive())
            self.assertEqual([b['replacementAllowed'] for b in draft['blocks']], [True, False, False])
            self.assertEqual([b['replacementPNG'] for b in draft['blocks']], ['verified-closed-png', None, None])
            pending.set_result('second-closed-png'); task.join(1)
            final = json.loads((directory / 'state.json').read_text())['page']
            self.assertEqual([b['id'] for b in final['blocks']], [b['id'] for b in draft['blocks']])
            self.assertEqual([b['replacementPNG'] for b in final['blocks']],
                             ['verified-closed-png', 'second-closed-png', 'verified-open-png'])
            self.assertEqual(final['skippedCount'], 1)

    def test_deduplication_is_identical_before_and_after_repair(self):
        with tempfile.TemporaryDirectory() as folder:
            directory, ready = Path(folder), Future()
            ready.set_result(None)
            worker['finish_page'](directory, [self.block(), self.block('b2')], 0, {'b1': ready}, time.monotonic())
            draft = json.loads((directory / 'text.json').read_text())
            final = json.loads((directory / 'state.json').read_text())['page']
            self.assertEqual([b['id'] for b in draft['blocks']], ['b1'])
            self.assertEqual([b['id'] for b in final['blocks']], ['b1'])

    def test_repair_timeout_exception_is_not_confused_with_pending_future(self):
        with tempfile.TemporaryDirectory() as folder:
            failed = Future(); failed.set_exception(TimeoutError('repair failed'))
            with self.assertRaises(TimeoutError):
                worker['finish_page'](Path(folder), [self.block()], 0, {'b1': failed}, time.monotonic())


class GlyphReplacementTests(unittest.TestCase):
    def test_shaded_background_and_artwork_outside_glyphs_are_preserved(self):
        image = np.full((100, 140, 3), 210, np.uint8)
        cv2.rectangle(image, (2, 2), (137, 97), (0, 0, 0), 2)
        mask = np.zeros((100, 140), np.uint8)
        for y in (30, 50, 70):
            cv2.rectangle(image, (45, y), (85, y+4), (0, 0, 0), -1)
            cv2.rectangle(mask, (44, y-1), (86, y+5), 255, -1)
        patch = decode(replacement_patch(image, mask, [20, 15, 120, 90]))
        alpha = patch[:, :, 3]
        self.assertTrue(np.array_equal(alpha, mask[15:90, 20:120]))
        self.assertGreater(np.mean(patch[:, :, :3][alpha > 0]), 190)
        self.assertTrue(np.all(patch[:, :, :3][alpha == 0] == 0))
        result = image.copy()
        result[15:90, 20:120][alpha > 0] = patch[:, :, :3][alpha > 0]
        self.assertTrue(np.array_equal(result[mask == 0], image[mask == 0]))

    def test_punctuation_missed_by_neural_mask_is_erased(self):
        image = np.full((80, 80, 3), 228, np.uint8)
        cv2.circle(image, (40, 40), 3, (0, 0, 0), 1)
        ink = (cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) < 215).astype(np.uint8)
        _, labels, _, _ = cv2.connectedComponentsWithStats(ink, connectivity=8)
        patch = decode(replacement_patch(image, np.zeros_like(ink), [20, 20, 60, 60], labels, [1]))
        self.assertGreater(patch[:, :, 3].sum(), 0)
        self.assertGreater(np.mean(patch[:, :, :3][patch[:, :, 3] > 0]), 200)

    def test_empty_mask_does_not_produce_an_erasure_layer(self):
        image = np.full((40, 40, 3), 228, np.uint8)
        self.assertIsNone(replacement_patch(image, np.zeros((40, 40), np.uint8), [2, 2, 38, 38]))

    def small_caption(self):
        image = np.full((60, 100, 3), 254, np.uint8)
        mask = np.zeros((60, 100), np.uint8)
        mask[20:40, 20:80] = 255
        for x in range(23, 79, 7):
            cv2.rectangle(image, (x, 23), (x+3, 36), (0, 0, 0), -1)
        return image, mask, [20, 20, 80, 40]

    def test_small_flat_caption_does_not_require_a_solid_erasure_or_neural_repair(self):
        image, mask, box = self.small_caption()
        self.assertIsNone(replacement_patch(image, mask, box, open_text=True))
        def unexpected_repair(*args):
            self.fail('verified flat caption must not run neural inpainting')
        patch = decode(replacement_patch(image, mask, box, open_text=True,
                                        restorer=unexpected_repair, font_size=12))
        alpha = patch[:, :, 3] > 0
        self.assertLessEqual(np.mean(alpha), .95)
        result = image.copy()
        result[20:40, 20:80][alpha] = patch[:, :, :3][alpha]
        self.assertFalse(np.any(result[20:40, 20:80] < 190))
        self.assertTrue(np.array_equal(result[mask == 0], image[mask == 0]))
        self.assertIsNone(replacement_patch(image, mask, box, open_text=True, font_size=24))

    def test_small_caption_fallback_rejects_diagonal_and_mismatching_backgrounds(self):
        image, mask, box = self.small_caption()
        cv2.line(image, (10, 10), (90, 50), (0, 0, 0), 3)
        self.assertIsNone(replacement_patch(image, mask, box, open_text=True, font_size=12))
        image, mask, box = self.small_caption()
        crop = image[20:40, 20:80]
        crop[np.all(crop > 200, axis=2)] = 220
        self.assertIsNone(replacement_patch(image, mask, box, open_text=True, font_size=12))

    def test_small_caption_keeps_neighboring_ink_outside_its_patch(self):
        image, mask, box = self.small_caption()
        cv2.rectangle(image, (80, 23), (84, 36), (0, 0, 0), -1)
        patch = decode(replacement_patch(image, mask, box, open_text=True, font_size=12))
        alpha = patch[:, :, 3] > 0
        result = image.copy()
        result[20:40, 20:80][alpha] = patch[:, :, :3][alpha]
        self.assertEqual(patch.shape[:2], (20, 60))
        self.assertTrue(np.array_equal(result[:, 80:], image[:, 80:]))


class RecognitionTests(unittest.TestCase):
    def test_parallel_detector_waits_for_complete_hints_and_cancel_does_not_hang(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            def publish():
                time.sleep(.03)
                temporary = directory / 'hints.tmp'
                temporary.write_text('[{"text":"おはよう"}]')
                temporary.replace(directory / 'hints.json')
            thread = threading.Thread(target=publish); thread.start()
            self.assertEqual(worker['read_hints'](directory, True), [{'text': 'おはよう'}])
            thread.join()
            (directory / 'hints.json').unlink()
            (directory / 'cancel').touch()
            self.assertEqual(worker['read_hints'](directory, True), [])

    def test_batches_preserve_ids_and_stop_before_returning_cancelled_results(self):
        batches = []
        original = worker['recognize_crops']
        def recognize(ocr, crops):
            batches.append(len(crops))
            return ['あ' + str(int(crop[0, 0, 0])) for crop in crops]
        worker['recognize_crops'] = recognize
        image = np.zeros((60, 20, 3), np.uint8)
        for index in range(3):
            image[index*20:(index+1)*20] = index
        boxes = [(index+1, [0, index*20, 20, (index+1)*20]) for index in range(3)]
        try:
            with tempfile.TemporaryDirectory() as folder:
                directory = Path(folder)
                values = list(worker['recognized_boxes'](None, image, boxes, {1: {'ja'}, 2: {'ja'}, 3: {'ja'}},
                                                       {1: 10, 2: 10, 3: 10}, directory, 2))
                self.assertEqual(batches, [2, 1])
                self.assertEqual([(v[0], v[1], v[3]) for v in values], [(0, 1, 'あ0'), (1, 2, 'あ1'), (2, 3, 'あ2')])
                stream = worker['recognized_boxes'](None, image, boxes, {1: {'ja'}, 2: {'ja'}, 3: {'ja'}},
                                                    {1: 10, 2: 10, 3: 10}, directory, 2)
                self.assertEqual(next(stream)[1], 1)
                (directory / 'cancel').touch()
                self.assertEqual(list(stream), [])
        finally:
            worker['recognize_crops'] = original

    def test_incomplete_batch_fails_instead_of_silently_losing_bubbles(self):
        original = worker['recognize_crops']
        worker['recognize_crops'] = lambda ocr, crops: []
        try:
            with tempfile.TemporaryDirectory() as folder, self.assertRaises(ValueError):
                list(worker['recognized_boxes'](None, np.zeros((20, 20, 3), np.uint8), [(1, [0, 0, 20, 20])],
                                               {1: {'ja'}}, {1: 10}, Path(folder), 8))
        finally:
            worker['recognize_crops'] = original

    def test_system_ocr_recovers_unknown_japanese_without_duplicate_boxes(self):
        block = SimpleNamespace(xyxy=[10, 10, 100, 50], font_size=20, language='unknown')
        hints = [{'box': [12, 12, 98, 48], 'text': 'おはよう', 'confidence': .9},
                 {'box': [200, 200, 260, 240], 'text': 'またね', 'confidence': .9},
                 {'box': [300, 300, 360, 340], 'text': 'あ', 'confidence': .4}]
        result = worker['supplement_candidates']([block], hints)
        self.assertEqual(len(result), 2)
        self.assertTrue(all(b.language == 'ja' for b in result))

    def test_open_bubble_is_kept_for_ocr_and_english_controls_are_excluded(self):
        labels = np.ones((100, 120), np.int32)
        stats = np.array([[0, 0, 0, 0, 0], [0, 0, 120, 100, 12000]], np.int32)
        blocks = [SimpleNamespace(xyxy=[20, 20, 50, 80], font_size=12, language='ja'),
                  SimpleNamespace(xyxy=[60, 20, 100, 40], font_size=12, language='eng')]
        groups, _, languages = worker['group_candidates'](blocks, labels, stats, {0, 1})
        self.assertEqual(len(groups), 1)
        self.assertLess(next(iter(groups)), 0)
        self.assertEqual(next(iter(languages.values())), {'ja'})

    def test_closed_bubble_lines_merge_without_inflating_total(self):
        labels = np.ones((100, 120), np.int32)
        labels[10:90, 10:110] = 2
        stats = np.array([[0, 0, 0, 0, 0], [0, 0, 120, 100, 4000], [10, 10, 100, 80, 8000]], np.int32)
        blocks = [SimpleNamespace(xyxy=box, font_size=12, language='ja')
                  for box in [[25, 25, 45, 75], [65, 25, 85, 75]]]
        groups, _, _ = worker['group_candidates'](blocks, labels, stats, {0, 1})
        self.assertEqual(list(groups), [2])

    def test_dense_line_uses_bubble_ring_and_merges_with_other_lines(self):
        labels = np.ones((140, 160), np.int32)
        labels[10:130, 10:150] = 2
        labels[25:50, 25:130] = 0  # Ink fills a tight detector box.
        stats = np.array([[0, 0, 160, 140, 2625], [0, 0, 160, 140, 5600],
                          [10, 10, 140, 120, 14175]], np.int32)
        blocks = [SimpleNamespace(xyxy=box, font_size=20, language='ja')
                  for box in [[25, 25, 130, 50], [25, 75, 130, 100]]]
        groups, _, _ = worker['group_candidates'](blocks, labels, stats, {0, 1})
        self.assertEqual(list(groups), [2])
        self.assertLess(groups[2][1], 25)
        self.assertGreater(groups[2][3], 100)

    def test_kanji_only_dialogue_uses_detector_language_and_empty_text_fails(self):
        accept = worker['japanese_text']
        self.assertTrue(accept('雨', {'ja'}))
        self.assertTrue(accept('おはよう', {'unknown'}))
        self.assertFalse(accept('设置', {'unknown'}))
        self.assertFalse(accept('', {'ja'}))

    def test_page_with_only_open_japanese_lettering_is_retained(self):
        groups = {-1: [10, 10, 60, 90]}
        self.assertEqual(worker['reading_groups'](groups, {-1: 12}), groups)

    def test_gray_bubble_with_small_outline_break_stays_one_region(self):
        gray = np.full((160, 200), 255, np.uint8)
        cv2.rectangle(gray, (20, 20), (180, 140), 208, -1)
        cv2.rectangle(gray, (20, 20), (180, 140), 0, 2)
        gray[19:22, 90] = 208
        labels, stats, exterior = worker['bubble_regions'](gray)
        blocks = [SimpleNamespace(xyxy=box, font_size=15, language='ja')
                  for box in [[40, 40, 80, 120], [120, 40, 160, 120]]]
        groups, _, _ = worker['group_candidates'](blocks, labels, stats, exterior)
        self.assertEqual(len(groups), 1)
        self.assertGreater(next(iter(groups)), 0)

    def test_punctuation_is_preserved_without_counting_as_failed_text(self):
        self.assertTrue(worker['punctuation_only']('……！！'))
        self.assertFalse(worker['punctuation_only'](''))
        self.assertFalse(worker['punctuation_only']('朝！！'))
        self.assertFalse(worker['punctuation_only']('ABC'))
        self.assertFalse(worker['japanese_text']('・…！！', {'ja'}))

    def test_failed_crop_is_retried_once_with_padding(self):
        seen = []
        def recognize(image):
            seen.append(image.size)
            return '' if len(seen) == 1 else 'おはよう'
        text = worker['recognize_text'](recognize, np.full((80, 30, 3), 255, np.uint8), {'ja'}, 20)
        self.assertEqual(text, 'おはよう')
        self.assertEqual(len(seen), 2)
        self.assertGreater(seen[1][0], seen[0][0])

    def test_punctuation_does_not_trigger_an_ocr_retry(self):
        seen = []
        def recognize(image):
            seen.append(image.size)
            return '……！！'
        worker['recognize_text'](recognize, np.full((80, 30, 3), 255, np.uint8), {'ja'}, 20)
        self.assertEqual(len(seen), 1)

    def test_unknown_open_toolbar_text_does_not_become_japanese_hallucinations(self):
        labels = np.ones((100, 120), np.int32)
        stats = np.array([[0, 0, 0, 0, 0], [0, 0, 120, 100, 12000]], np.int32)
        groups, _, _ = worker['group_candidates']([
            SimpleNamespace(xyxy=[20, 20, 100, 40], font_size=12, language='unknown')
        ], labels, stats, {0, 1})
        self.assertEqual(groups, {})

    def test_unknown_curved_lettering_next_to_japanese_dialogue_is_retained(self):
        labels = np.ones((160, 200), np.int32)
        stats = np.array([[0, 0, 0, 0, 0], [0, 0, 200, 160, 32000]], np.int32)
        blocks = [SimpleNamespace(xyxy=[80, 30, 120, 130], font_size=20, language='ja'),
                  SimpleNamespace(xyxy=[45, 40, 70, 120], font_size=22, language='unknown')]
        groups, _, _ = worker['group_candidates'](blocks, labels, stats, {0, 1})
        self.assertEqual(len(groups), 2)

    def test_open_text_far_from_bubbles_is_kept_but_tiny_thumbnails_are_excluded(self):
        groups = {1: [130, 350, 320, 550], -1: [190, 620, 270, 650], -2: [120, 10, 230, 40]}
        self.assertEqual(set(worker['reading_groups'](groups, {1: 20, -1: 18, -2: 5})), {1, -1})

    def test_partial_system_hint_cannot_drop_a_caption_column(self):
        hint = [{'box': [0, 0, 20, 100], 'text': '本当の願いを', 'confidence': 1.0}]
        self.assertIsNone(worker['reliable_hint']([0, 0, 50, 100], hint, '彼女の本当の願いを'))

    def test_independent_phrase_restores_one_missing_voicing_mark(self):
        hints = [{'box': [0, 0, 50, 100], 'text': '観たバンド', 'confidence': .3}]
        self.assertEqual(worker['restore_voicing']('去年観たハンドがかっこよかった', [0, 0, 50, 100], hints), '去年観たバンドがかっこよかった')
        self.assertEqual(worker['restore_voicing']('私はハンドボール部', [0, 0, 50, 100], hints), '私はハンドボール部')

    def test_large_panel_interior_is_not_a_small_bubble(self):
        labels = np.ones((400, 400), np.int32); labels[30:350, 30:350] = 2
        stats = np.array([[0, 0, 0, 0, 0], [0, 0, 400, 400, 57600], [30, 30, 320, 320, 102400]], np.int32)
        candidate = SimpleNamespace(xyxy=[100, 100, 125, 155], font_size=25, language='ja')
        groups, _, _ = worker['group_candidates']([candidate], labels, stats, {0, 1})
        self.assertTrue(all(key < 0 for key in groups))

    def test_local_ink_search_covers_the_same_nearby_components(self):
        labels = np.zeros((500, 500), np.int32)
        labels[30:35, 30:35] = 1
        labels[75:80, 75:80] = 2
        labels[400:405, 400:405] = 3
        self.assertEqual(set(worker['nearby_ink_ids'](labels, [20, 20, 100, 100])), {1, 2})

    def test_recovery_keeps_missing_lettering_but_excludes_reader_controls_and_scrollbar(self):
        image = np.full((400, 800, 3), 50, np.uint8)
        image[:360, 200:600] = 255
        image[:, 795:] = 255
        mask = np.zeros((400, 800), np.uint8)
        mask[30:180, 220:235] = 220  # Missed elongated lettering.
        mask[80:140, 400:440] = 220  # Existing detected dialogue.
        mask[375:395, 410:450] = 220  # Reader control.
        boxes = worker['recover_candidates'](image, mask, [SimpleNamespace(xyxy=[395,75,445,145])])
        self.assertEqual(len(boxes), 1)
        self.assertLess(boxes[0].xyxy[1], 30)
        labels, stats, exterior = worker['bubble_regions'](cv2.cvtColor(image, cv2.COLOR_BGR2GRAY))
        groups, _, _ = worker['group_candidates'](boxes, labels, stats, exterior)
        self.assertEqual(len(groups), 1)
        self.assertLess(next(iter(groups)), 0)

    def test_same_overlapping_text_is_deduplicated_but_separate_repeated_bubbles_remain(self):
        blocks = [dict(id='a', text='まあこうなるか．．', textStyle='outlinedDark', bounds=dict(x=10,y=10,width=100,height=100)),
                  dict(id='b', text='まあこうなるか．．．', textStyle=None, bounds=dict(x=30,y=30,width=40,height=40)),
                  dict(id='c', text='まあこうなるか', textStyle=None, bounds=dict(x=200,y=30,width=40,height=40))]
        self.assertEqual([b['id'] for b in worker['unique_blocks'](blocks)], ['b', 'c'])


if __name__ == '__main__':
    unittest.main()
