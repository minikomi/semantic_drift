<?php

declare(strict_types=1);

require __DIR__ . '/../vendor/autoload.php';

use GuzzleHttp\Client;
use GuzzleHttp\Exception\GuzzleException;

if ($argc !== 2) {
    fwrite(STDERR, sprintf("usage: %s <todos-url>\n", $argv[0]));
    exit(1);
}

$client = new Client([
    'timeout' => 10.0,
    'http_errors' => false,
]);

try {
    $response = $client->get($argv[1]);
} catch (GuzzleException $e) {
    fwrite(STDERR, $e->getMessage() . "\n");
    exit(1);
}

$statusCode = $response->getStatusCode();
if ($statusCode < 200 || $statusCode >= 300) {
    $reason = $response->getReasonPhrase();
    $status = $reason === '' ? (string)$statusCode : $statusCode . ' ' . $reason;
    fwrite(STDERR, "bad status: " . $status . "\n");
    exit(1);
}

try {
    $todos = json_decode((string)$response->getBody(), true, 512, JSON_THROW_ON_ERROR);
} catch (JsonException $e) {
    fwrite(STDERR, $e->getMessage() . "\n");
    exit(1);
}

if (!is_array($todos)) {
    fwrite(STDERR, "json: cannot unmarshal non-array into Go value of type []main.Todo\n");
    exit(1);
}

$timezone = new DateTimeZone(date_default_timezone_get());
$today = new DateTimeImmutable('today', $timezone);

$byUser = [];

foreach ($todos as $todo) {
    if (!is_array($todo)) {
        $todo = [];
    }

    $userId = (int)($todo['userId'] ?? 0);
    if (!isset($byUser[$userId])) {
        $byUser[$userId] = [
            'userId' => $userId,
            'completed' => 0,
            'missed' => 0,
        ];
    }

    if ((bool)($todo['completed'] ?? false)) {
        $byUser[$userId]['completed']++;
        continue;
    }

    $dueDate = (string)($todo['dueDate'] ?? '');
    $due = DateTimeImmutable::createFromFormat('!Y-m-d', $dueDate, $timezone);
    $errors = DateTimeImmutable::getLastErrors();
    if ($due === false || ($errors !== false && ($errors['warning_count'] > 0 || $errors['error_count'] > 0))) {
        fwrite(STDERR, parseDateError($dueDate) . "\n");
        exit(1);
    }

    if ($due < $today) {
        $byUser[$userId]['missed']++;
    }
}

$rows = array_values($byUser);
usort($rows, static function (array $a, array $b): int {
    if ($a['completed'] !== $b['completed']) {
        return $b['completed'] <=> $a['completed'];
    }
    if ($a['missed'] !== $b['missed']) {
        return $b['missed'] <=> $a['missed'];
    }
    return $a['userId'] <=> $b['userId'];
});

echo "USER  COMPLETED  MISSED\n";
foreach ($rows as $row) {
    printf("%-5d %-10d %d\n", $row['userId'], $row['completed'], $row['missed']);
}

function parseDateError(string $value): string
{
    if ($value === '') {
        return 'parsing time "" as "2006-01-02": cannot parse "" as "2006"';
    }

    return sprintf('parsing time %s as "2006-01-02": cannot parse as date', json_encode($value, JSON_UNESCAPED_SLASHES));
}
