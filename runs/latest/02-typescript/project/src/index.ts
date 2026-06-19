import axios from "axios";
import { format, isValid, parse } from "date-fns";

type Todo = {
  userId: number;
  id: number;
  completed: boolean;
  dueDate: string;
};

type Summary = {
  userId: number;
  completed: number;
  missed: number;
};

function usage(): never {
  console.error(`usage: ${process.argv[1]} <todos-url>`);
  process.exit(1);
}

function fail(message: unknown): never {
  if (message instanceof Error) {
    console.error(message.message);
  } else {
    console.error(String(message));
  }
  process.exit(1);
}

function parseDateOnlyInLocalTime(value: string, today: Date): Date {
  const parsed = parse(value, "yyyy-MM-dd", today);
  if (!isValid(parsed) || format(parsed, "yyyy-MM-dd") !== value) {
    throw new Error(`parsing time "${value}" as "2006-01-02": cannot parse "${value}" as "2006"`);
  }
  return parsed;
}

async function main(): Promise<void> {
  if (process.argv.length !== 3) {
    usage();
  }

  const url = process.argv[2];
  let todos: Todo[];

  try {
    const response = await axios.get<Todo[]>(url, {
      timeout: 10_000,
      responseType: "json",
      validateStatus: () => true,
    });

    if (response.status < 200 || response.status >= 300) {
      fail(`bad status: ${response.status} ${response.statusText}`);
    }

    todos = response.data;
  } catch (error) {
    fail(error);
  }

  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const byUser = new Map<number, Summary>();

  for (const todo of todos) {
    let summary = byUser.get(todo.userId);
    if (summary === undefined) {
      summary = { userId: todo.userId, completed: 0, missed: 0 };
      byUser.set(todo.userId, summary);
    }

    if (todo.completed) {
      summary.completed += 1;
    } else {
      let due: Date;
      try {
        due = parseDateOnlyInLocalTime(todo.dueDate, today);
      } catch (error) {
        fail(error);
      }
      if (due.getTime() < today.getTime()) {
        summary.missed += 1;
      }
    }
  }

  const rows = [...byUser.values()].sort((a, b) => {
    if (a.completed !== b.completed) {
      return b.completed - a.completed;
    }
    if (a.missed !== b.missed) {
      return b.missed - a.missed;
    }
    return a.userId - b.userId;
  });

  console.log("USER  COMPLETED  MISSED");
  for (const summary of rows) {
    console.log(`${String(summary.userId).padEnd(5, " ")} ${String(summary.completed).padEnd(10, " ")} ${summary.missed}`);
  }
}

main().catch((error: unknown) => fail(error));
