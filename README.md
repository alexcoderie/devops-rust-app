# Simple pipeline that automatically run tests and deploys an application

Through this project I aim to implement a pipeline that automatically run tests and deploys an application on every push, using GitHub Actions. There are two pipelines, one for running checks, tests, building the project, and one for deploying the project.

## Technologies used

- Rust Programming Language
- axum
- Fly.io
- Docker
- Git
- GitHub

## Pipelines

For a more modular way of working I chose to separate the workflow into two separate pipelines.
### Build and Test

As the name suggests, this pipeline is responsible for running tests and building the application. Besides that, it also checks for formatting and performs static program analysis on the source code.

| <div style="width:290px">Stage</div> |                                                                     Role                                                                     |
| :----------------------------------: | :------------------------------------------------------------------------------------------------------------------------------------------: |
|             Format check             |               Using `cargo fmt --check` it check if the source code is correctly formatted, but it does not format it itself.                |
|                 Lint                 |                    Using `cargo clippy -- -D warnings` it performs static program analysis and treats warnings as errors.                    |
|                Tests                 |           Using `cargo test --verbose --color always` it runs the applications tests and applies syntax highlighting to the logs.            |
|                Build                 | Using `cargo build --verbose --release` it builds the project. In order for this stage to run, it is required for the previous ones to pass. |

| <div style="width:290px">Action</div> |       <div style="width:290px">Role</div>        |
| :-----------------------------------: | :----------------------------------------------: |
|         `actions/checkout@v6`         |      Used for checking out the repository.       |
|    `dtolnay/rust-toolchain@stable`    |      Used for installing the rust toolchain      |
|        `Swatiem/rust-cache@v2`        | Implements smart caching for rust/cargo projects |

### Fly Deploy

This pipeline is responsible for deploying the project. It has a single stage which runs `flyctl deploy --remote-only`. The `--remote-only` flag is used for building the application on a remote builder instance instead of using the local docker daemon. 

After deployment, the application can be accessed at https://my-rust-web-app.fly.dev/ 

### Branch rules

Alongside the workflow automation, GitHub allows you to set branch rules and environments. Firstly, pushing directly on main is not allowed, therefore adding a new feature is done on a separate branch and then merged into `main`. Hence, the `Build and Test` pipeline runs when a Pull Request is opened. If the pipeline has ran successfully and someone approved the Pull Request, the merge can be completed. After the merge, `Fly deploy` runs, which also requires an approval upon start-up. 

## Project Structure

```text
my-app
├── .github
│   └── workflows
│       ├── build_test.yml
│       └── fly-deploy.yml
├── src
│   ├── router
│   │   ├── mod.rs
│   │   └── router.rs
│   └── main.rs
├── tests
│   └── api.rs
├── Cargo.lock
├── Cargo.toml
├── Dockerfile
└── fly.toml
```

## Lessons Learned

I chose Rust as the programming language for this app because it is a language that I want to become proficient in. Even though, web application development is not an area that I am particularly interested in, it was better suited for this kind of project and it didn't hurt to play around with it, especially using this language.

Alongside that, I got the chance to get familiar with GitHub's automation tools and, considering that it is the main repository storing platform that I use, I can apply this knowledge to my personal projects.

I also discovered Fly.io, which is the IaaS platform that I used. It was really convenient to use it for this project, as it provides great support for Rust applications and deploys via the command line.

## References

[Rust Programming Language](https://rust-lang.org/)
[Axum](https://docs.rs/axum/latest/axum/)
[GitHub Actions Rust](https://docs.github.com/en/actions/tutorials/build-and-test-code/rust)
[Fly.io](https://fly.io/)
[Fly.io Rust](https://fly.io/docs/rust/)