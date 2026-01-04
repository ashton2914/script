# Scripts

## How to use

```sh
bash -c "$(curl -fsSL https://ashtreetown.org/resource/script/[script_name.sh])"
```

## AI Generate Rules:

- Please do not run the test script directly, as it may not have been developed for the current system.
- Scripts should be compatible with both Linux and macOS.
- Scripts should follow the standard structure of the user directory or the official standard directory structure defined by the software during configuration, unless the user has other specific requirements.
- Installation scripts should prioritize methods that do not require root privileges, minimizing system coupling to facilitate subsequent management and removal by the user.
- If environment variable configuration is involved, it should be considered that the user may have already correctly configured environment variables in other files rather than just in .zshrc or .bashrc, instead of simply querying only the .zshrc or .bashrc files. The script should be able to correctly identify and avoid duplicate configuration of environment variables.
- The script should feature both uninstall and repair functions. The uninstall function will delete all files installed by the installation process and remind users to manually remove any configured environment variables. The logic for the repair command is to perform an uninstallation followed by an installation, intended to fix environments that have been inadvertently damaged. Upon running the script, prompt the user to choose: 1. install, 2. uninstall, 3. repair. Enter the corresponding number to execute the desired function. The default action is 1. install.
- Reference format for the comment information at the beginning of the file:
    ```sh
    # =================================================================
    # Script Name: [script_name.sh]
    # Description: [description]
    # OS: Linux_x86_64, Linux_arm64, macOS_x86_64, macOS_arm64
    # Date: [date]
    # =================================================================
    ```