import 'package:test/test.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

void main() {
  test('parses Antigravity weekly and 5h quota groups', () {
    final windows = parseAntigravityQuotaSummary({
      'groups': [
        {
          'displayName': 'Gemini',
          'buckets': [
            {
              'window': '5h',
              'remainingFraction': 0.71,
              'resetTime': '2026-10-29T16:00:00Z',
            },
            {
              'window': 'weekly',
              'remainingFraction': 0.295,
              'resetTime': '2026-10-31T00:00:00Z',
            },
          ],
        },
        {
          'displayName': 'Claude & GPT',
          'buckets': [
            {
              'window': '5h',
              'remainingFraction': 1.0,
              'resetTime': '2026-10-29T17:00:00Z',
            },
            {
              'window': 'weekly',
              'remainingFraction': 0.094,
              'resetTime': '2026-10-30T09:00:00Z',
            },
          ],
        },
      ],
    });

    expect(windows.length, 4);
    expect(
      windows.firstWhere((w) => w.id == 'antigravity-gemini-session').usedPercent,
      closeTo(29, 0.001),
    );
    expect(
      windows.firstWhere((w) => w.id == 'antigravity-claude-gpt-session').remainingPercent,
      100,
    );
    expect(
      windows.firstWhere((w) => w.id == 'antigravity-gemini-weekly').remainingPercent,
      closeTo(29.5, 0.001),
    );
    expect(
      windows.firstWhere((w) => w.id == 'antigravity-claude-gpt-weekly').remainingPercent,
      closeTo(9.4, 0.001),
    );
  });

  test('parses Gemini image quota', () {
    final window = parseAntigravityImageQuota({
      'models': {
        'gemini-3.1-flash-image': {
          'quotaInfo': {
            'remainingFraction': 0.29,
            'resetTime': '2026-10-29T16:00:00Z',
          },
        },
      },
    });

    expect(window, isNotNull);
    expect(window!.label, 'Gemini 3.1 Flash Image');
    expect(window.remainingPercent, closeTo(29, 0.001));
  });
}
