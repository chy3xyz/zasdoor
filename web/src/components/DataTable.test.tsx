import { render, screen } from '@solidjs/testing-library';
import { describe, expect, it } from 'vitest';

import DataTable, { type Column } from './DataTable';

interface Row {
  id: number;
  name: string;
}

const columns: Column<Row>[] = [
  { key: 'id', title: 'ID', render: (r) => <span>{r.id}</span> },
  { key: 'name', title: '名称', render: (r) => <span>{r.name}</span> },
];

describe('DataTable', () => {
  it('renders headers and rows', () => {
    render(() => (
      <DataTable
        columns={columns}
        rows={[
          { id: 1, name: 'Alice' },
          { id: 2, name: 'Bob' },
        ]}
        rowKey={(r) => String(r.id)}
        total={2}
        page={1}
        totalPages={1}
        loading={false}
        error={null}
        onPageChange={() => {}}
      />
    ));
    expect(screen.getByText('ID')).toBeTruthy();
    expect(screen.getByText('名称')).toBeTruthy();
    expect(screen.getByText('Alice')).toBeTruthy();
    expect(screen.getByText('Bob')).toBeTruthy();
  });

  it('shows empty text when no rows', () => {
    render(() => (
      <DataTable
        columns={columns}
        rows={[]}
        rowKey={(r) => String(r.id)}
        total={0}
        page={1}
        totalPages={1}
        loading={false}
        error={null}
        emptyText="暂无数据"
        onPageChange={() => {}}
      />
    ));
    expect(screen.getByText('暂无数据')).toBeTruthy();
  });
});
