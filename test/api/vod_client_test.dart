// Specs vod.search.days, vod.search.day_clips, vod.search.player_id_fallback
// (tier 1). Shapes and golden JSON come from the Windows repo
// (tests/unit/test_dtos.py, tests/phase4/test_clip_search_lan.py).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tapo_tv/api/camera_dtos.dart';
import 'package:tapo_tv/api/tapo_errors.dart';
import 'package:tapo_tv/api/vod_client.dart';

String _j(Object o) => jsonEncode(o);

const _terminal = 'A1B2C3D4E5F60718293A4B5C6D7E8F90';

/// Answers clip searches page by page; records every request.
class _FakeVodControl implements VodControl {
  _FakeVodControl(this.answer);
  final List<ControlItem> Function(Map<String, dynamic> request) answer;
  final List<Map<String, dynamic>> requests = [];

  @override
  Future<List<ControlItem>> send(List<Map<String, dynamic>> batch) async {
    requests.addAll(batch);
    return [for (final r in batch) ...answer(r)];
  }
}

Map<String, dynamic> _search(Map<String, dynamic> request) =>
    ((request['params'] as Map)['playback'] as Map)['search_video_with_utc'] as Map<String, dynamic>;

Map<String, dynamic> _clip(int start, int end, {String type = '2'}) => {
      'search_video_results_1': {'startTime': start, 'endTime': end, 'video_type': type},
    };

ControlItem _page(List<Map<String, dynamic>> clips, {int more = 0}) => ControlItem(
      method: 'searchVideoWithUTC',
      result: {
        'playback': {'search_video_results': clips, 'to_be_continued': more},
      },
    );

void main() {
  group('days', () {
    test('search days request has yyyyMMdd and channel [0]', () {
      expect(
        _j(buildSearchDaysRequest(start: DateTime(2024, 2, 9), end: DateTime(2024, 3, 1))),
        '{"method":"searchDateWithVideo","params":{"playback":{"search_year_utility":'
        '{"channel":[0],"start_date":"20240209","end_date":"20240301"}}}}',
      );
    });

    test('parseDays unwraps single-key maps and sorts', () {
      final days = parseDays({
        'playback': {
          'search_results': [
            {'search_results_1': {'date': '20240211'}},
            {'search_results_2': {'date': '20240209'}},
            {'search_results_3': {'date': '20240210'}},
          ],
        },
      });
      expect(days, ['20240209', '20240210', '20240211']);
      expect(parseDays({'playback': {'search_results': []}}), isEmpty);
    });

    test('parseDays rejects non 8-digit date', () {
      for (final bad in ['2024-02-09', '240209', '202402091', 'abcdefgh', '']) {
        expect(
          () => parseDays({
            'playback': {
              'search_results': [
                {'search_results_1': {'date': bad}},
              ],
            },
          }),
          throwsA(isA<TapoProtocolError>()),
          reason: bad,
        );
      }
    });

    test('daysWithRecordings sends the request through the control path', () async {
      final control = _FakeVodControl((r) => [
            const ControlItem(method: 'searchDateWithVideo', result: {
              'playback': {
                'search_results': [
                  {'search_results_1': {'date': '20240209'}},
                ],
              },
            }),
          ]);
      final days = await VodClient(control: control).daysWithRecordings(
        DateTime(2024, 2, 9),
        DateTime(2024, 3, 1),
      );
      expect(days, ['2024-02-09']);
      expect(control.requests.single['method'], 'searchDateWithVideo');
    });

    test('isoDay turns yyyyMMdd into YYYY-MM-DD and rejects impossible dates', () {
      expect(isoDay('20240229'), '2024-02-29');
      for (final bad in ['20230229', '20241301', '20240100', '2024-02-0']) {
        expect(() => isoDay(bad), throwsA(isA<TapoProtocolError>()), reason: bad);
      }
    });
  });

  group('day clips', () {
    test('day clips request legacy id form', () {
      expect(
        _j(buildDayClipsRequest(startTime: 100, endTime: 200, startIndex: 0, endIndex: 99)),
        '{"method":"searchVideoWithUTC","params":{"playback":{"search_video_with_utc":'
        '{"id":1,"channel":0,"start_time":100,"end_time":200,"start_index":0,"end_index":99}}}}',
      );
    });

    test('parseDayClips spec template', () {
      final clips = parseDayClips({
        'playback': {
          'search_video_results': [
            {
              'search_video_results_1': {
                'startTime': 1735900000,
                'endTime': 1735900120,
                'vedio_type': '2',
                'video_type': '2',
              },
            },
          ],
          'to_be_continued': 0,
        },
      });
      expect(clips, hasLength(1));
      expect(clips.single.start, 1735900000);
      expect(clips.single.end, 1735900120);
      expect(clips.single.eventType, 2);
      expect(clips.single.durationSeconds, 120);
    });

    test('parseDayClips string times and vedio_type fallback', () {
      final clips = parseDayClips({
        'playback': {
          'search_video_results': [
            {'a': {'startTime': '1735900000', 'endTime': '1735900060', 'video_type': '6'}},
            {'b': {'startTime': 1735900100, 'endTime': 1735900160, 'vedio_type': '2'}},
            {'c': {'startTime': 1735900200, 'endTime': 1735900260}},
          ],
        },
      });
      expect(clips.map((c) => c.eventType), [6, 2, 0]);
      expect(clips.first.start, 1735900000);
    });

    test('parseDayClips sorts by start and handles empty', () {
      final clips = parseDayClips({
        'playback': {
          'search_video_results': [_clip(300, 400), _clip(100, 200)],
        },
      });
      expect(clips.map((c) => c.start), [100, 300]);
      expect(parseDayClips({'playback': {'search_video_results': [], 'to_be_continued': 0}}), isEmpty);
    });

    test('parseDayClips rejects non-numeric times', () {
      for (final bad in [
        {'startTime': 'abc', 'endTime': 10},
        {'startTime': 10, 'endTime': null},
        {'endTime': 10},
      ]) {
        expect(
          () => parseDayClips({
            'playback': {
              'search_video_results': [
                {'x': bad},
              ],
            },
          }),
          throwsA(isA<TapoProtocolError>()),
          reason: '$bad',
        );
      }
    });

    test('hasMoreClips', () {
      expect(hasMoreClips({'playback': {'to_be_continued': 1}}), isTrue);
      expect(hasMoreClips({'playback': {'to_be_continued': '1'}}), isTrue);
      expect(hasMoreClips({'playback': {'to_be_continued': 0}}), isFalse);
      expect(hasMoreClips({'playback': {}}), isFalse);
    });

    test('day window is local midnight to +86399 in UTC seconds', () {
      final (start, end) = dayWindowSeconds(DateTime(2025, 1, 3));
      expect(start, DateTime(2025, 1, 3).millisecondsSinceEpoch ~/ 1000);
      expect(end - start, 86399);
      final (start2, _) = dayWindowSeconds(DateTime(2025, 1, 3, 17, 30, 12));
      expect(start2, start, reason: 'time of day is ignored');
    });

    test('recordingsForDay pages until to_be_continued is 0', () async {
      final control = _FakeVodControl((r) {
        final s = _search(r);
        if (s['start_index'] == 0) {
          return [_page([for (var i = 0; i < 100; i++) _clip(1000 + i * 10, 1005 + i * 10)], more: 1)];
        }
        return [_page([for (var i = 0; i < 5; i++) _clip(5000 + i * 10, 5005 + i * 10)])];
      });
      final clips = await VodClient(control: control).recordingsForDay(DateTime(2025, 1, 3));
      expect(clips, hasLength(105));
      expect(clips.first.start, 1000);
      expect(clips.last.start, 5040);
      expect(control.requests.map((r) => (_search(r)['start_index'], _search(r)['end_index'])),
          [(0, 99), (100, 199)]);
      final (start, end) = dayWindowSeconds(DateTime(2025, 1, 3));
      expect(_search(control.requests.first)['start_time'], start);
      expect(_search(control.requests.first)['end_time'], end);
      expect(_search(control.requests.first)['id'], 1);
    });

    test('an empty page stops paging even when more is announced', () async {
      final control = _FakeVodControl((r) => [_page(const [], more: 1)]);
      final clips = await VodClient(control: control).recordingsForDay(DateTime(2025, 1, 3));
      expect(clips, isEmpty);
      expect(control.requests, hasLength(1));
    });

    test('paging is capped at 100 pages', () async {
      final control = _FakeVodControl((r) => [_page([_clip(1, 2)], more: 1)]);
      await VodClient(control: control).recordingsForDay(DateTime(2025, 1, 3));
      expect(control.requests, hasLength(100));
    });
  });

  group('player id fallback', () {
    test('player_id form replaces id', () {
      expect(
        _j(buildDayClipsRequest(
          startTime: 100,
          endTime: 200,
          startIndex: 0,
          endIndex: 49,
          playerId: 'abababababababababababababababab',
        )),
        '{"method":"searchVideoWithUTC","params":{"playback":{"search_video_with_utc":'
        '{"player_id":"abababababababababababababababab","channel":0,"start_time":100,'
        '"end_time":200,"start_index":0,"end_index":49}}}}',
      );
    });

    test('-71103 retries once with player_id and remembers the form', () async {
      final control = _FakeVodControl((r) {
        final s = _search(r);
        if (s.containsKey('id')) return [const ControlItem(method: 'searchVideoWithUTC', errorCode: -71103)];
        return [_page([_clip(100, 200)])];
      });
      final client = VodClient(control: control, terminalUuid: _terminal);
      final first = await client.recordingsForDay(DateTime(2025, 1, 3));
      expect(first, hasLength(1));
      expect(control.requests.map((r) => _search(r).containsKey('id')), [true, false]);
      expect(_search(control.requests.last)['player_id'], client.playerId);

      control.requests.clear();
      await client.recordingsForDay(DateTime(2025, 1, 4));
      expect(control.requests.map((r) => _search(r).containsKey('id')), [false],
          reason: 'the working form is remembered');
    });

    test('second -71103 is raised', () async {
      final control = _FakeVodControl(
        (r) => [const ControlItem(method: 'searchVideoWithUTC', errorCode: -71103)],
      );
      await expectLater(
        VodClient(control: control).recordingsForDay(DateTime(2025, 1, 3)),
        throwsA(isA<TapoDeviceError>().having((e) => e.code, 'code', -71103)),
      );
      expect(control.requests, hasLength(2));
    });

    test('player_id is 32 hex and stable per client', () {
      final fromTerminal = VodClient(control: _FakeVodControl((_) => []), terminalUuid: _terminal);
      expect(fromTerminal.playerId, 'a1b2c3d4e5f60718293a4b5c6d7e8f90');
      for (final terminal in [null, 'short', 'ZZZZ' * 8]) {
        final c = VodClient(control: _FakeVodControl((_) => []), terminalUuid: terminal);
        expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(c.playerId), isTrue, reason: '$terminal');
        expect(c.playerId, c.playerId);
      }
    });
  });
}
