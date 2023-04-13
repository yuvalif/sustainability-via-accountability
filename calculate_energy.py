import json

fp = open("rgw_traces.json")

data = json.load(fp)
durations = {}

def get_tag(tags, key, default=None):
    for item in tags:
        if item["key"] == key:
            return item["value"]
    return default


for trace in data["data"]:
    pod1 = get_tag(trace["processes"]["p1"]["tags"], "pod.name")
    pod2 = get_tag(trace["processes"]["p2"]["tags"], "pod.name") if "p2" in trace["processes"] else None
    pod3 = get_tag(trace["processes"]["p3"]["tags"], "pod.name") if "p3" in trace["processes"] else None
    pods = {"p1": pod1, "p2": pod2, "p3": pod3}
    # same bucket should be used for all spans in the trace
    spans = trace["spans"]
    bucket_name = get_tag(spans[0]["tags"], "bucket_name", "internal")
    for span in spans:
        pod_name = pods[span["processID"]]
        if pod_name is None:
            print("missing pod name for span: "+span["spanID"]+" in trace: "+trace["traceID"])
            continue
        duration = span["duration"]
        if pod_name in durations:
            if bucket_name in durations[pod_name]:
                durations[pod_name][bucket_name] += duration
            else: 
                durations[pod_name][bucket_name] = duration
            durations[pod_name]["total"] += duration
        else:
            durations[pod_name] = {bucket_name: duration, "total": duration}
           

# calculate the energy consumed by each pod during the test
start_energy = {}
fp = open("kepler_start.json")
data = json.load(fp)
for result in data["data"]["result"]:
    pod_name = result["metric"]["pod_name"]
    value = result["values"][0][1]
    start_energy[pod_name] = value


end_energy = {}
fp = open("kepler_end.json")
data = json.load(fp)
for result in data["data"]["result"]:
    pod_name = result["metric"]["pod_name"]
    value = result["values"][0][1]
    end_energy[pod_name] = value

energy_diff = {}
for end_item in end_energy.items():
    pod_name = end_item[0]
    if pod_name in start_energy:
        energy_diff[pod_name] = float(end_item[1]) - float(start_energy[pod_name])


bucket_energy = {}

for pod_stats in durations.items():
    pod_name = pod_stats[0]
    if pod_name in energy_diff:
        energy = energy_diff[pod_name]
    else:
        print("no energy information for pod: "+pod_name)
        continue
    total = int(pod_stats[1]["total"])
    for bucket_stats in pod_stats[1].items():
        bucket_name = bucket_stats[0]
        if bucket_name != "total":
            percent = int(bucket_stats[1])/total
            if bucket_name in bucket_energy:
                bucket_energy[bucket_name] += percent*energy
            else:
                bucket_energy[bucket_name] = percent*energy

from tabulate import tabulate

print(tabulate(bucket_energy.items(), headers=["bucket name", "energy (KJ)"], tablefmt='fancy_grid'))

