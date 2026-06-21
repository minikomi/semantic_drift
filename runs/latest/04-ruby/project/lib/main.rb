require "date"
require "httparty"

Summary = Struct.new(:userId, :completed, :missed)

def usage
  warn "usage: #{$PROGRAM_NAME} <todos-url>"
  exit 1
end

def fail_with(message)
  warn message.to_s
  exit 1
end

def parse_date_only_in_local_time(value, today)
  parsed = Date.strptime(value, "%Y-%m-%d")
  unless parsed.strftime("%Y-%m-%d") == value
    fail_with(%Q(parsing time "#{value}" as "2006-01-02": cannot parse "#{value}" as "2006"))
  end
  parsed
rescue Date::Error
  fail_with(%Q(parsing time "#{value}" as "2006-01-02": cannot parse "#{value}" as "2006"))
end

def main
  usage unless ARGV.length == 1

  url = ARGV[0]

  begin
    response = HTTParty.get(url, timeout: 10)
    unless response.code >= 200 && response.code < 300
      fail_with("bad status: #{response.code} #{response.message}")
    end
    todos = response.parsed_response
  rescue SystemExit
    raise
  rescue StandardError => error
    fail_with(error)
  end

  today = Date.today
  by_user = {}

  todos.each do |todo|
    user_id = todo.fetch("userId")
    summary = by_user[user_id]
    unless summary
      summary = Summary.new(user_id, 0, 0)
      by_user[user_id] = summary
    end

    if todo.fetch("completed")
      summary.completed += 1
    else
      due = parse_date_only_in_local_time(todo.fetch("dueDate"), today)
      summary.missed += 1 if due < today
    end
  end

  rows = by_user.values.sort_by { |summary| [-summary.completed, -summary.missed, summary.userId] }

  puts "USER  COMPLETED  MISSED"
  rows.each do |summary|
    puts format("%-5s %-10s %s", summary.userId.to_s, summary.completed.to_s, summary.missed)
  end
end

begin
  main
rescue SystemExit
  raise
rescue StandardError => error
  fail_with(error)
end
