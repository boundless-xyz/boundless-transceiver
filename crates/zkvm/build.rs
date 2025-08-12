// Copyright 2025 Boundless, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

use risc0_build_ethereum::generate_solidity_files;

// Paths where the generated Solidity files will be written.
const SOLIDITY_IMAGE_ID_PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../src/ImageID.sol");
const SOLIDITY_ELF_PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../src/tests/Elf.sol");

fn main() {
    let guests = risc0_build::embed_methods();

    // Generate Solidity source files for use with Forge.
    let solidity_opts = risc0_build_ethereum::Options::default()
        .with_image_id_sol_path(SOLIDITY_IMAGE_ID_PATH)
        .with_elf_sol_path(SOLIDITY_ELF_PATH);

    let _ = generate_solidity_files(guests.as_slice(), &solidity_opts);
}
