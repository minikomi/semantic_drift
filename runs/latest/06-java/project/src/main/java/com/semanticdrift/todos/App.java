package com.semanticdrift.todos;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.math.BigDecimal;
import java.time.DateTimeException;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.TimeUnit;
import java.util.regex.Pattern;

public final class App {
    private static final Pattern DATE_ONLY_RE = Pattern.compile("^\\d{4}-\\d{2}-\\d{2}$");
    private static final ObjectMapper JSON = new ObjectMapper();

    private App() {
    }

    public static void main(String[] args) {
        System.exit(run(args));
    }

    private static int run(String[] args) {
        if (args.length != 1) {
            System.err.println("usage: ./run.sh <url>");
            return 2;
        }

        try {
            OkHttpClient client = new OkHttpClient.Builder()
                    .callTimeout(10, TimeUnit.SECONDS)
                    .build();

            Request request = new Request.Builder().url(args[0]).get().build();
            try (Response response = client.newCall(request).execute()) {
                int statusCode = response.code();
                if (statusCode < 200 || statusCode >= 300) {
                    String reason = response.message();
                    String statusText = reason == null || reason.isEmpty() ? "" : " " + reason;
                    System.err.println("bad status: " + statusCode + statusText);
                    return 1;
                }

                ResponseBody body = response.body();
                String json = body == null ? "" : body.string();
                List<Map<String, Object>> todos = JSON.readValue(json, new TypeReference<>() {
                });

                OffsetDateTime today = localStartOfToday();
                Map<String, Summary> byUser = new LinkedHashMap<>();

                for (Map<String, Object> todo : todos) {
                    Object userId = todo.get("userId");
                    String key = stringify(userId);
                    Summary summary = byUser.computeIfAbsent(key, ignored -> new Summary(userId));

                    if (isTruthy(todo.get("completed"))) {
                        summary.completed++;
                    } else if (parseDateOnly(stringify(todo.get("dueDate"))).isBefore(today)) {
                        summary.missed++;
                    }
                }

                List<Summary> rows = new ArrayList<>(byUser.values());
                rows.sort((left, right) -> {
                    int completed = Integer.compare(right.completed, left.completed);
                    if (completed != 0) {
                        return completed;
                    }
                    int missed = Integer.compare(right.missed, left.missed);
                    if (missed != 0) {
                        return missed;
                    }
                    return comparePhpValues(left.userId, right.userId);
                });

                System.out.println("USER  COMPLETED  MISSED");
                for (Summary summary : rows) {
                    System.out.printf("%-5s %-10d %d%n", stringify(summary.userId), summary.completed, summary.missed);
                }
            }

            return 0;
        } catch (Throwable error) {
            System.err.println(Objects.toString(error.getMessage(), ""));
            return 1;
        }
    }

    private static OffsetDateTime parseDateOnly(String value) {
        if (!DATE_ONLY_RE.matcher(value).matches()) {
            throw new RuntimeException("parsing time \"" + value + "\" as \"2006-01-02\": cannot parse \"" + value + "\" as \"2006\"");
        }

        int year = Integer.parseInt(value.substring(0, 4));
        int month = Integer.parseInt(value.substring(5, 7));
        int day = Integer.parseInt(value.substring(8, 10));

        if (year < 1 || year > 9999) {
            throw new RuntimeException("year " + year + " is out of range");
        }
        if (month < 1 || month > 12) {
            throw new RuntimeException("month must be in 1..12");
        }

        try {
            LocalDate.of(year, month, day);
        } catch (DateTimeException error) {
            throw new RuntimeException("parsing time \"" + value + "\": day out of range");
        }

        return OffsetDateTime.parse(String.format("%04d-%02d-%02dT00:00:00Z", year, month, day));
    }

    private static OffsetDateTime localStartOfToday() throws Exception {
        Process process = new ProcessBuilder("date", "+%Y-%m-%dT00:00:00%z")
                .redirectError(ProcessBuilder.Redirect.DISCARD)
                .start();

        String output;
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream()))) {
            output = reader.readLine();
        }
        process.waitFor();

        if (output != null && !output.trim().isEmpty()) {
            return OffsetDateTime.parse(output.trim(), DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ssXX"));
        }

        ZoneId zone = localTimezone();
        return ZonedDateTime.now(zone).toLocalDate().atStartOfDay(zone).toOffsetDateTime();
    }

    private static ZoneId localTimezone() {
        String timezone = System.getenv("TZ");
        if (timezone != null && !timezone.isEmpty()) {
            return ZoneId.of(timezone);
        }
        return ZoneId.systemDefault();
    }

    private static boolean isTruthy(Object value) {
        if (value == null) {
            return false;
        }
        if (value instanceof Boolean bool) {
            return bool;
        }
        if (value instanceof Number number) {
            return number.doubleValue() != 0.0;
        }
        return !stringify(value).isEmpty();
    }

    private static String stringify(Object value) {
        if (value == null) {
            return "";
        }
        if (value instanceof BigDecimal decimal) {
            return decimal.stripTrailingZeros().toPlainString();
        }
        return String.valueOf(value);
    }

    private static int comparePhpValues(Object left, Object right) {
        if (left instanceof Number leftNumber && right instanceof Number rightNumber) {
            return Double.compare(leftNumber.doubleValue(), rightNumber.doubleValue());
        }
        return stringify(left).compareTo(stringify(right));
    }

    private static final class Summary {
        private final Object userId;
        private int completed;
        private int missed;

        private Summary(Object userId) {
            this.userId = userId;
        }
    }
}
