# Copyright (c) 2024, NVIDIA CORPORATION. All rights reserved.
#
# NVIDIA CORPORATION and its licensors retain all intellectual property
# and proprietary rights in and to this software, related documentation
# and any modifications thereto. Any use, reproduction, disclosure or
# distribution of this software and related documentation without an express
# license agreement from NVIDIA CORPORATION is strictly prohibited.

import sys
import pathlib
import subprocess

import pytest

from isaac_common_py import subprocess_utils


@pytest.mark.parametrize('print_mode', ['all', 'tail'])
def test_run_command(tmp_path: pathlib.Path, print_mode):
    expected = [f'line {i}' for i in range(12)]
    log_file = tmp_path / 'log.txt'
    output = subprocess_utils.run_command(
        mnemonic='Example Command',
        command=[sys.executable, '-c', 'for i in range(12): print(f"line {i}")'],
        log_file=log_file,
        print_mode=print_mode,
    )
    assert output == expected
    assert log_file.read_text().splitlines() == expected


@pytest.mark.parametrize('print_mode', ['all', 'tail'])
def test_failed_command_preserves_log(tmp_path: pathlib.Path, print_mode):
    log_file = tmp_path / 'log.txt'
    with pytest.raises(subprocess.CalledProcessError) as error:
        subprocess_utils.run_command(
            mnemonic='Failing Command',
            command=[sys.executable, '-c', 'print("failure detail"); raise SystemExit(7)'],
            log_file=log_file,
            print_mode=print_mode,
        )
    assert error.value.returncode == 7
    assert log_file.read_text() == 'failure detail\n'
