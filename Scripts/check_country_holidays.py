#!/usr/bin/env python3
"""Compile the owned production holiday adapter and perform public read-only provider checks.
No app workspace, tasks, accounts, calendar permission or credentials are used.
"""
import argparse,json,subprocess,tempfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--core-build',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
product=a.core_build/'out/Products/Debug'
if (product/'libTaskfoldCore.a').exists():
 modules=product;link=['-L',str(product),'-lTaskfoldCore']
else:
 paths=list(a.core_build.rglob('Modules/TaskfoldCore.swiftmodule'))
 if len(paths)!=1: raise RuntimeError('Build the owned Core package first')
 modules=paths[0].parent;link=[str(x) for x in sorted((modules.parent/'TaskfoldCore.build').glob('*.swift.o'))]
source=r'''
@testable import TaskfoldCore
import Foundation
@main struct Check {
 static func main() async throws {
  let countries = try CountryHolidayCalendar.countries(data: await CountryHolidayCalendar.fetch(CountryHolidayCalendar.request()))
  guard countries.contains(where: { $0.countryCode == "DK" }), countries.contains(where: { $0.countryCode == "DE" }) else { fatalError("Missing provider coverage") }
  var results: [[String: Any]] = []
  for code in ["DK", "DE"] {
   let data = try await CountryHolidayCalendar.fetch(CountryHolidayCalendar.request(country: code, year: 2027))
   let calendar = try CountryHolidayCalendar.snapshot(data: data, year: 2027, country: code)
   guard calendar.days(subdivision: nil).contains(where: { $0.date == "2027-01-01" }) else { fatalError("Missing nationwide new year") }
   if code == "DE" { guard calendar.days(subdivision: "DE-BY").contains(where: { $0.date == "2027-01-06" }) else { fatalError("Missing regional holiday") } }
   results.append(["country": code, "year": 2027, "national_dates": calendar.days(subdivision: nil).count, "regional_codes": calendar.subdivisions, "sha256": calendar.digest])
  }
  let output: [String: Any] = ["provider": "Nager.Holidays Community v4", "countries": countries.count, "read_only": true, "checks": results]
  print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted,.sortedKeys]), as: UTF8.self))
 }
}
'''
with tempfile.TemporaryDirectory(prefix='taskfold-country-check-') as folder:
 folder=Path(folder);f=folder/'Check.swift';f.write_text(source)
 subprocess.run(['xcrun','swiftc','-parse-as-library','-I',str(modules),str(f),*link,'-o',str(folder/'Check')],check=True)
 result=subprocess.run([str(folder/'Check')],check=True,text=True,capture_output=True,timeout=90)
 value=json.loads(result.stdout);a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(value,indent=2)+'\n');print(result.stdout)
