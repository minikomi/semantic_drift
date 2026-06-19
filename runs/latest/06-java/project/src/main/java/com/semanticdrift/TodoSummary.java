package com.semanticdrift;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;

import java.io.IOException;
import java.math.BigDecimal;
import java.text.DecimalFormat;
import java.text.DecimalFormatSymbols;
import java.time.Duration;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

public final class TodoSummary {
  private static final ObjectMapper MAPPER = new ObjectMapper();

  private TodoSummary() {
  }

  private record HttpResult(int status, String reason, String body) {
  }

  private record DateOnly(int year, int month, int day) {
  }

  private static final class Summary {
    private final JsonNode userId;
    private int completed;
    private int missed;

    private Summary(JsonNode userId) {
      this.userId = userId;
    }
  }

  public static void main(String[] args) {
    if (args.length != 1) {
      System.err.println("usage: " + commandName() + " <todos-url>");
      System.exit(1);
    }

    try {
      HttpResult response = httpGet(args[0]);
      if (response.status < 200 || response.status >= 300) {
        String message = "bad status: " + response.status;
        if (!response.reason.isEmpty()) {
          message += " " + response.reason;
        }
        failWith(message);
      }

      JsonNode todos = MAPPER.readTree(response.body);
      DateOnly today = todayLocal();
      Map<String, Summary> byUser = new LinkedHashMap<>();

      for (JsonNode todo : todos) {
        JsonNode userId = required(todo, "userId");
        String key = jsonKey(userId);
        Summary summary = byUser.computeIfAbsent(key, unused -> new Summary(userId));

        if (required(todo, "completed").asBoolean()) {
          summary.completed += 1;
        } else {
          DateOnly due = parseDateOnlyInLocalTime(required(todo, "dueDate").asText());
          if (dateLess(due, today)) {
            summary.missed += 1;
          }
        }
      }

      List<Summary> rows = new ArrayList<>(byUser.values());
      rows.sort(Comparator
          .comparingInt((Summary row) -> row.completed).reversed()
          .thenComparing(Comparator.comparingInt((Summary row) -> row.missed).reversed())
          .thenComparing((a, b) -> userIdLess(a.userId, b.userId) ? -1 : userIdLess(b.userId, a.userId) ? 1 : 0));

      System.out.println("USER  COMPLETED  MISSED");
      for (Summary row : rows) {
        printRow(displayValue(row.userId), Integer.toString(row.completed), row.missed);
      }
    } catch (Exception error) {
      failWith(error.getMessage() == null ? error.toString() : error.getMessage());
    }
  }

  private static String commandName() {
    String command = System.getProperty("sun.java.command", "");
    int space = command.indexOf(' ');
    if (space >= 0) {
      command = command.substring(0, space);
    }
    return command.isEmpty() ? "todo-summary" : command;
  }

  private static void failWith(String message) {
    System.err.println(message);
    System.exit(1);
  }

  private static HttpResult httpGet(String url) throws IOException {
    OkHttpClient client = new OkHttpClient.Builder()
        .followRedirects(true)
        .followSslRedirects(true)
        .callTimeout(Duration.ofSeconds(10))
        .build();
    Request request = new Request.Builder().url(url).get().build();
    try (Response response = client.newCall(request).execute()) {
      ResponseBody body = response.body();
      return new HttpResult(response.code(), response.message(), body == null ? "" : body.string());
    }
  }

  private static JsonNode required(JsonNode node, String field) {
    JsonNode value = node.get(field);
    if (value == null) {
      throw new IllegalArgumentException("key '" + field + "' not found");
    }
    return value;
  }

  private static String jsonKey(JsonNode value) {
    return value.toString();
  }

  private static String displayValue(JsonNode value) {
    if (value.isTextual()) {
      return value.asText();
    }
    if (value.isIntegralNumber()) {
      return value.asText();
    }
    if (value.isFloatingPointNumber() || value.isBigDecimal() || value.isBigInteger()) {
      return cppDefaultDoubleString(value.asDouble());
    }
    if (value.isBoolean()) {
      return value.asBoolean() ? "true" : "false";
    }
    if (value.isNull()) {
      return "";
    }
    return value.toString();
  }

  private static String cppDefaultDoubleString(double value) {
    if (Double.isNaN(value)) {
      return "nan";
    }
    if (Double.isInfinite(value)) {
      return value > 0 ? "inf" : "-inf";
    }

    double abs = Math.abs(value);
    DecimalFormatSymbols symbols = DecimalFormatSymbols.getInstance(Locale.ROOT);
    DecimalFormat format;
    if (abs != 0.0 && (abs < 0.0001 || abs >= 1000000.0)) {
      format = new DecimalFormat("0.#####E0", symbols);
      String rendered = format.format(value).replace("E", "e");
      int exponent = rendered.indexOf('e');
      if (exponent >= 0 && exponent + 1 < rendered.length()) {
        char sign = rendered.charAt(exponent + 1);
        if (sign != '-' && sign != '+') {
          rendered = rendered.substring(0, exponent + 1) + "+" + rendered.substring(exponent + 1);
        }
        int expStart = exponent + 2;
        while (expStart + 1 < rendered.length() && rendered.charAt(expStart) == '0') {
          rendered = rendered.substring(0, expStart) + rendered.substring(expStart + 1);
        }
      }
      return rendered;
    }

    format = new DecimalFormat("0.#####", symbols);
    return format.format(value);
  }

  private static boolean userIdLess(JsonNode a, JsonNode b) {
    if (a.isNumber() && b.isNumber()) {
      return a.asDouble() < b.asDouble();
    }
    if (a.isTextual() && b.isTextual()) {
      return a.asText().compareTo(b.asText()) < 0;
    }
    if (a.isBoolean() && b.isBoolean()) {
      return Boolean.compare(a.asBoolean(), b.asBoolean()) < 0;
    }
    return a.toString().compareTo(b.toString()) < 0;
  }

  private static boolean isLeapYear(int year) {
    return (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
  }

  private static int daysInMonth(int year, int month) {
    int[] days = {0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    if (month == 2 && isLeapYear(year)) {
      return 29;
    }
    if (month < 1 || month > 12) {
      return 0;
    }
    return days[month];
  }

  private static String parseErrorMessage(String value) {
    return "parsing time \"" + value + "\" as \"2006-01-02\": cannot parse \"" + value + "\" as \"2006\"";
  }

  private static DateOnly parseDateOnlyInLocalTime(String value) {
    boolean shapeOk = value.length() == 10 && value.charAt(4) == '-' && value.charAt(7) == '-';
    for (int i = 0; i < value.length() && shapeOk; i++) {
      if (i == 4 || i == 7) {
        continue;
      }
      shapeOk = Character.isDigit(value.charAt(i));
    }

    if (!shapeOk) {
      failWith(parseErrorMessage(value));
    }

    int year = Integer.parseInt(value.substring(0, 4));
    int month = Integer.parseInt(value.substring(5, 7));
    int day = Integer.parseInt(value.substring(8, 10));
    if (month < 1 || month > 12 || day < 1 || day > daysInMonth(year, month)) {
      failWith(parseErrorMessage(value));
    }
    return new DateOnly(year, month, day);
  }

  private static DateOnly todayLocal() {
    LocalDate now = LocalDate.now();
    return new DateOnly(now.getYear(), now.getMonthValue(), now.getDayOfMonth());
  }

  private static boolean dateLess(DateOnly a, DateOnly b) {
    if (a.year != b.year) {
      return a.year < b.year;
    }
    if (a.month != b.month) {
      return a.month < b.month;
    }
    return a.day < b.day;
  }

  private static void printRow(String userId, String completed, int missed) {
    System.out.print(userId);
    if (userId.length() < 5) {
      System.out.print(" ".repeat(5 - userId.length()));
    }
    System.out.print(' ');
    System.out.print(completed);
    if (completed.length() < 10) {
      System.out.print(" ".repeat(10 - completed.length()));
    }
    System.out.print(' ');
    System.out.println(missed);
  }
}
