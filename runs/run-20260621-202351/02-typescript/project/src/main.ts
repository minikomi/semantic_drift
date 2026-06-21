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

function exitWithError(err: unknown): never {
  if (err instanceof Error) {
    console.error(err.message);
  } else {
    console.error(String(err));
  }
  process.exit(1);
}

function parseGoDateOnlyInLocalTime(value: string): Date {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (match === null) {
    throw new Error(`parsing time ${JSON.stringify(value)} as ${JSON.stringify("2006-01-02")}: cannot parse date`);
  }

  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const parsed = new Date(year, month - 1, day, 0, 0, 0, 0);

  if (
    parsed.getFullYear() !== year ||
    parsed.getMonth() !== month - 1 ||
    parsed.getDate() !== day
  ) {
    throw new Error(`parsing time ${JSON.stringify(value)}: day out of range`);
  }

  return parsed;
}

async function main(): Promise<void> {
  if (process.argv.length !== 3) {
    usage();
  }

  const url = process.argv[2];
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000);

  let response: Response;
  try {
    response = await fetch(url, { signal: controller.signal });
  } catch (err) {
    exitWithError(err);
  } finally {
    clearTimeout(timeout);
  }

  if (response.status < 200 || response.status >= 300) {
    const status = response.statusText.length > 0 ? `${response.status} ${response.statusText}` : String(response.status);
    console.error(`bad status: ${status}`);
    process.exit(1);
  }

  let todos: Todo[];
  try {
    todos = (await response.json()) as Todo[];
  } catch (err) {
    exitWithError(err);
  }

  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 0, 0, 0, 0);

  const byUser = new Map<number, Summary>();
  for (const todo of todos) {
    let summary = byUser.get(todo.userId);
    if (summary === undefined) {
      summary = { userId: todo.userId, completed: 0, missed: 0 };
      byUser.set(todo.userId, summary);
    }

    if (todo.completed) {
      summary.completed++;
    } else {
      let due: Date;
      try {
        due = parseGoDateOnlyInLocalTime(todo.dueDate);
      } catch (err) {
        exitWithError(err);
      }
      if (due.getTime() < today.getTime()) {
        summary.missed++;
      }
    }
  }

  const rows = Array.from(byUser.values());
  rows.sort((a, b) => {
    if (a.completed !== b.completed) {
      return b.completed - a.completed;
    }
    if (a.missed !== b.missed) {
      return b.missed - a.missed;
    }
    return a.userId - b.userId;
  });

  process.stdout.write("USER  COMPLETED  MISSED\n");
  for (const summary of rows) {
    const user = String(summary.userId).padEnd(5, " ");
    const completed = String(summary.completed).padEnd(10, " ");
    process.stdout.write(`${user} ${completed} ${summary.missed}\n`);
  }
}

main().catch(exitWithError);
