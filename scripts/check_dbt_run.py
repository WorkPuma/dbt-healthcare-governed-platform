#!/usr/bin/env python3
"""Check dbt Cloud run status and errors."""

import os
import requests
import sys
from datetime import datetime, timezone

TOKEN = os.environ.get("DBT_CLOUD_API_TOKEN", "").strip()
ACCOUNT_ID = '70403103941825'
HOST = 'dd894.us1.dbt.com'

def get_headers():
    if not TOKEN:
        raise RuntimeError('DBT_CLOUD_API_TOKEN is required')
    return {'Authorization': f'Token {TOKEN}'}

def get_recent_runs(limit=10):
    """Get recent runs."""
    response = requests.get(
        f'https://{HOST}/api/v2/accounts/{ACCOUNT_ID}/runs/',
        headers=get_headers(),
        params={'limit': limit, 'order_by': '-id'}
    )
    return response.json()['data']

def get_run_details(run_id):
    """Get details for a specific run."""
    response = requests.get(
        f'https://{HOST}/api/v2/accounts/{ACCOUNT_ID}/runs/{run_id}/',
        headers=get_headers()
    )
    return response.json()['data']

def get_run_results(run_id):
    """Get run_results.json artifact."""
    response = requests.get(
        f'https://{HOST}/api/v2/accounts/{ACCOUNT_ID}/runs/{run_id}/artifacts/run_results.json',
        headers=get_headers()
    )
    if response.status_code == 200:
        return response.json()
    return None

def get_dbt_log(run_id):
    """Get dbt.log artifact."""
    response = requests.get(
        f'https://{HOST}/api/v2/accounts/{ACCOUNT_ID}/runs/{run_id}/artifacts/dbt.log',
        headers=get_headers()
    )
    if response.status_code == 200:
        return response.text
    return None

def main():
    print(f"Current UTC time: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')}")
    print()
    
    # Get recent runs
    runs = get_recent_runs(limit=20)
    
    print("Recent dbt Cloud Runs:")
    print("=" * 80)
    for r in runs:
        status = r['status_humanized']
        run_id = r['id']
        created = r['created_at'][:19]
        git_branch = r.get('git_branch', 'N/A')
        marker = " <-- FAILED" if status == 'Error' else ""
        print(f"{run_id}: {status:12} | {git_branch:30} | {created}{marker}")
    
    # Find most recent error
    error_runs = [r for r in runs if r['status_humanized'] == 'Error']
    
    if not error_runs:
        print("\nNo failed runs found in recent history.")
        return
    
    # Get details on most recent error
    error_run = error_runs[0]
    run_id = error_run['id']
    
    print(f"\n{'=' * 80}")
    print(f"Details for Failed Run: {run_id}")
    print("=" * 80)
    
    details = get_run_details(run_id)
    print(f"Status: {details['status_humanized']}")
    print(f"Created: {details['created_at']}")
    print(f"Finished: {details.get('finished_at', 'N/A')}")
    print(f"Duration: {details.get('duration_humanized', 'N/A')}")
    print(f"Git Branch: {details.get('git_branch', 'N/A')}")
    print(f"Trigger: {details.get('trigger', {}).get('cause', 'N/A') if details.get('trigger') else 'N/A'}")
    
    # Get run results
    results = get_run_results(run_id)
    
    if results:
        print("\nRun Results:")
        print("-" * 80)
        
        # Find all non-success results
        failed = []
        for r in results.get('results', []):
            status = r.get('status', 'unknown').lower()
            if status not in ['success', 'pass', 'skipped']:
                failed.append(r)
        
        if failed:
            print(f"Found {len(failed)} failed/error node(s):\n")
            for r in failed:
                node = r.get('unique_id', 'unknown')
                status = r.get('status', 'unknown')
                msg = r.get('message', 'No message')
                if msg:
                    msg = msg[:1000]
                print(f"FAILED: {node}")
                print(f"  Status: {status}")
                print(f"  Message: {msg}")
                print()
        else:
            print("No individual model failures in run_results.json")
            print("Checking dbt.log for errors...")
    
    # Always try to get dbt.log for ERROR lines
    dbt_log = get_dbt_log(run_id)
    if dbt_log:
        # Extract ERROR lines
        error_lines = [line for line in dbt_log.split('\n') if 'ERROR' in line or 'Error' in line]
        if error_lines:
            print("\nERROR lines from dbt.log:")
            print("-" * 80)
            for line in error_lines[:20]:  # Show first 20 error lines
                print(line)
    else:
        print("\nCould not fetch dbt.log")
        print("Check the dbt Cloud UI for detailed logs:")
        print(f"  https://{HOST}/deploy/{ACCOUNT_ID}/projects/70403103995546/runs/{run_id}")

if __name__ == "__main__":
    main()
