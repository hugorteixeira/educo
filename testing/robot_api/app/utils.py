import subprocess

def run_gpio_command(command: str) -> None:
    """Run a 'gpio' CLI command and raise RuntimeError on failure."""
    try:
        proc = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=5)
        if proc.returncode != 0:
            raise RuntimeError(f"GPIO error: {proc.stderr.strip()} [{command}]")
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"GPIO timeout [{command}]")
