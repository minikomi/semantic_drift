interface Todo {
  userId: number;
  id: number;
  completed: boolean;
  dueDate: string;
}

interface Summary {
  userId: number;
  completed: number;
  missed: number;
}

function usage(): never {
  console.error(`usage: ${process.argv[1]} <todos-url>`);
  process.exit(1);
}

function parseDateOnly(value: string): Date {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new Error(`parsing time "${value}" as "2006-01-02": cannot parse "${value}" as "2006"`);
  }

  const [yearText, monthText, dayText] = value.split("-");
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const date = new Date(Date.UTC(year, month - 1, day));

  if (
    date.getUTCFullYear() !== year ||
    date.getUTCMonth() !== month - 1 ||
    date.getUTCDate() !== day
  ) {
    throw new Error(`parsing time "${value}": day out of range`);
  }

  return date;
}

function localStartOfToday(): Date {
  const now = new Date();
  return new Date(now.getFullYear(), now.getMonth(), now.getDate());
}

async function main(): Promise<void> {
  if (process.argv.length !== 3) {
    usage();
  }

  const response = await fetch(process.argv[2], {
    signal: AbortSignal.timeout(10_000),
  });

  if (response.status < 200 || response.status >= 300) {
    const statusText = response.statusText ? ` ${response.statusText}` : "";
    console.error(`bad status: ${response.status}${statusText}`);
    process.exit(1);
  }

  const todos = (await response.json()) as Todo[];
  const today = localStartOfToday();
  const byUser = new Map<number, Summary>();

  for (const todo of todos) {
    let summary = byUser.get(todo.userId);
    if (summary === undefined) {
      summary = { userId: todo.userId, completed: 0, missed: 0 };
      byUser.set(todo.userId, summary);
    }

    if (todo.completed) {
      summary.completed += 1;
    } else if (parseDateOnly(todo.dueDate).getTime() < today.getTime()) {
      summary.missed += 1;
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

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
