import sys

def parse_epoch_times(log_file):
    epoch_times = []
    with open(log_file, 'r') as f:
        for line in f:
            # [OUTPUT] 2026-04-03T10:20:24.733075 Ending epoch 5 - 6 steps completed in 3.38 s
            if "Ending epoch" in line and "completed in" in line:
                parts = line.strip().split()
                try:
                    time_str = parts[-2]  # e.g. "3.38"
                    time_sec = float(time_str)  # convert to float
                    epoch_times.append(time_sec)
                except (ValueError, IndexError):
                    continue
    return epoch_times

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python parse-epoch-times.py <log_file>")
        sys.exit(1)

    log_file = sys.argv[1]
    epoch_times = parse_epoch_times(log_file)
    print("Parsed epoch times:")
    for i, time in enumerate(epoch_times):
        print(f"Epoch {i+1}: {time} seconds")

    # remove first epoch time if it is an outlier (e.g. much larger than the rest)
    # if epoch_times and (epoch_times[0] > 2 * (sum(epoch_times[1:]) / len(epoch_times[1:]))):
    #     print(f"Removing outlier epoch time: {epoch_times[0]} seconds")
    #     epoch_times = epoch_times[1:]
    avg = sum(epoch_times) / len(epoch_times) if epoch_times else 0
    std = (sum((x - avg) ** 2 for x in epoch_times) / len(epoch_times)) ** 0.5 if epoch_times else 0
    print(f"Average: {avg:.2f} seconds")
    print(f"Standard deviation: {std:.2f} seconds")