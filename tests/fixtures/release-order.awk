/bash scripts\/build-tarball.sh/ { if (tag || publish) exit 1; build++ }
/git tag -a/ { if (build != 1) exit 1; tag++ }
/git push origin "\$VERSION"/ { if (tag != 1) exit 1; pushed++ }
/uses: softprops\/action-gh-release/ { if (pushed != 1) exit 1; publish++ }
END { if (build != 1 || tag != 1 || pushed != 1 || publish != 1) exit 1 }
