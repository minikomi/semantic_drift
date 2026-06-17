<?php

declare(strict_types=1);

namespace SemanticDriftTodos;

use DateTimeImmutable;
use DateTimeZone;
use GuzzleHttp\Client;
use Throwable;

final class App
{
    private const DATE_ONLY_RE = '/^\d{4}-\d{2}-\d{2}$/';

    /**
     * @param list<string> $argv
     */
    public static function main(array $argv): int
    {
        if (count($argv) !== 1) {
            fwrite(STDERR, "usage: ./run.sh <url>\n");
            return 2;
        }

        try {
            $client = new Client([
                'http_errors' => false,
                'timeout' => 10,
            ]);
            $response = $client->get($argv[0]);
            $statusCode = $response->getStatusCode();

            if ($statusCode < 200 || $statusCode >= 300) {
                $reason = $response->getReasonPhrase();
                $statusText = $reason === '' ? '' : ' ' . $reason;
                fwrite(STDERR, "bad status: {$statusCode}{$statusText}\n");
                return 1;
            }

            $todos = json_decode((string) $response->getBody(), true, 512, JSON_THROW_ON_ERROR);
            $today = self::localStartOfToday();
            $byUser = [];

            foreach ($todos as $todo) {
                $userId = $todo['userId'];
                $key = (string) $userId;

                if (!isset($byUser[$key])) {
                    $byUser[$key] = [
                        'user_id' => $userId,
                        'completed' => 0,
                        'missed' => 0,
                    ];
                }

                if ($todo['completed']) {
                    $byUser[$key]['completed']++;
                } elseif (self::parseDateOnly($todo['dueDate']) < $today) {
                    $byUser[$key]['missed']++;
                }
            }

            $rows = array_values($byUser);
            usort($rows, static function (array $left, array $right): int {
                return [$right['completed'], $right['missed'], $left['user_id']]
                    <=> [$left['completed'], $left['missed'], $right['user_id']];
            });

            echo "USER  COMPLETED  MISSED\n";
            foreach ($rows as $summary) {
                echo str_pad((string) $summary['user_id'], 5, ' ', STR_PAD_RIGHT)
                    . ' '
                    . str_pad((string) $summary['completed'], 10, ' ', STR_PAD_RIGHT)
                    . ' '
                    . $summary['missed']
                    . "\n";
            }

            return 0;
        } catch (Throwable $error) {
            fwrite(STDERR, $error->getMessage() . "\n");
            return 1;
        }
    }

    private static function parseDateOnly(string $value): DateTimeImmutable
    {
        if (preg_match(self::DATE_ONLY_RE, $value) !== 1) {
            throw new \RuntimeException('parsing time "' . $value . '" as "2006-01-02": cannot parse "' . $value . '" as "2006"');
        }

        [$yearText, $monthText, $dayText] = explode('-', $value);
        $year = (int) $yearText;
        $month = (int) $monthText;
        $day = (int) $dayText;

        if ($year < 1 || $year > 9999) {
            throw new \RuntimeException("year {$year} is out of range");
        }

        if ($month < 1 || $month > 12) {
            throw new \RuntimeException('month must be in 1..12');
        }

        if (!checkdate($month, $day, $year)) {
            throw new \RuntimeException('parsing time "' . $value . '": day out of range');
        }

        return new DateTimeImmutable(sprintf('%04d-%02d-%02d 00:00:00', $year, $month, $day), new DateTimeZone('UTC'));
    }

    private static function localStartOfToday(): DateTimeImmutable
    {
        $systemDate = shell_exec('date "+%Y-%m-%dT00:00:00%z" 2>/dev/null');
        if ($systemDate !== null && trim($systemDate) !== '') {
            return new DateTimeImmutable(trim($systemDate));
        }

        $now = new DateTimeImmutable('now', self::localTimezone());

        return $now->setTime(0, 0, 0);
    }

    private static function localTimezone(): DateTimeZone
    {
        $timezone = getenv('TZ');
        if (is_string($timezone) && $timezone !== '') {
            return new DateTimeZone($timezone);
        }

        return new DateTimeZone(date_default_timezone_get());
    }
}
