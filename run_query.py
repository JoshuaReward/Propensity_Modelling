#!/usr/bin/env python3
"""
run_query.py

Usage examples:
  python run_query.py --query-file derived.schemetrans.sql --output results.csv
  python run_query.py --query "SELECT TOP 10 * FROM [WH_AllPublishers].[Derived].[Customer]" --output out.csv

Credentials are read from environment variables:
  SQL_SERVER, SQL_DATABASE, SQL_USER, SQL_PASSWORD, SQL_DRIVER
If SQL_USER is not set the script will attempt trusted connection.

Requires: pyodbc
Install with: pip install pyodbc
"""
import os
import argparse
import pyodbc
import csv
import sys


def get_connection(driver, server, database, user, password):
    if user:
        conn_str = (
            f"DRIVER={{{driver}}};SERVER={server};DATABASE={database};UID={user};PWD={password}"
        )
    else:
        # trusted connection (Windows Integrated)
        conn_str = f"DRIVER={{{driver}}};SERVER={server};DATABASE={database};Trusted_Connection=yes"
    return pyodbc.connect(conn_str, autocommit=True)


def read_query(args):
    if args.query_file:
        with open(args.query_file, 'r', encoding='utf-8') as f:
            return f.read()
    if args.query:
        return args.query
    raise ValueError('Either --query-file or --query must be provided')


def write_csv(cursor, output_path):
    cols = [column[0] for column in cursor.description]
    with open(output_path, 'w', newline='', encoding='utf-8') as fh:
        writer = csv.writer(fh)
        writer.writerow(cols)
        for row in cursor:
            writer.writerow([None if v is None else str(v) for v in row])


def main():
    parser = argparse.ArgumentParser(description='Run SQL and export to CSV')
    parser.add_argument('--query-file', help='Path to SQL file')
    parser.add_argument('--query', help='Inline SQL query')
    parser.add_argument('--output', '-o', required=True, help='Output CSV path')
    parser.add_argument('--driver', default=os.environ.get('SQL_DRIVER', 'ODBC Driver 17 for SQL Server'))
    parser.add_argument('--server', default=os.environ.get('SQL_SERVER'))
    parser.add_argument('--database', default=os.environ.get('SQL_DATABASE'))
    parser.add_argument('--user', default=os.environ.get('SQL_USER'))
    parser.add_argument('--password', default=os.environ.get('SQL_PASSWORD'))
    args = parser.parse_args()

    if not args.server or not args.database:
        print('ERROR: SQL_SERVER and SQL_DATABASE must be provided via env or flags', file=sys.stderr)
        sys.exit(2)

    try:
        sql = read_query(args)
    except Exception as e:
        print('ERROR reading query:', e, file=sys.stderr)
        sys.exit(2)

    try:
        conn = get_connection(args.driver, args.server, args.database, args.user, args.password)
        cur = conn.cursor()
        cur.execute(sql)
        write_csv(cur, args.output)
        print(f'Wrote results to {args.output}')
    except Exception as e:
        print('ERROR executing query:', e, file=sys.stderr)
        sys.exit(3)
    finally:
        try:
            cur.close()
            conn.close()
        except Exception:
            pass


if __name__ == '__main__':
    main()
