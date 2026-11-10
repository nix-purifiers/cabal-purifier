import ctypes, json, pathlib, shlex, subprocess, sys
prefix = pathlib.Path(sys.argv[1]).resolve()
root = ctypes.CDLL(str(prefix/'lib/answer/libanswer.so'))
root.purifier_answer.argtypes = [ctypes.c_int]; root.purifier_term.restype = None
assert root.purifier_init() == 1
assert root.purifier_answer(0) == 42
class Info(ctypes.Structure):
    _fields_ = [('fname',ctypes.c_char_p),('base',ctypes.c_void_p),('symbol',ctypes.c_char_p),('address',ctypes.c_void_p)]
host = ctypes.CDLL(None)
def origin(name):
    info = Info(); assert host.dladdr(ctypes.cast(getattr(root,name),ctypes.c_void_p),ctypes.byref(info))
    return pathlib.Path(info.fname.decode()).resolve()
def field(package, name):
    return subprocess.check_output(['ghc-pkg','--global','field',package,name,'--simple-output'],text=True).strip()
def exported(path, marker):
    rows = [line.split() for line in subprocess.check_output(['readelf','--dyn-syms','--wide',str(path)],text=True).splitlines()]
    names = [r[7] for r in rows if len(r)>=8 and r[0].endswith(':') and r[0][:-1].isdigit()
             and r[6]!='UND' and r[4] in {'GLOBAL','WEAK'} and r[5] in {'DEFAULT','PROTECTED'}]
    return next(name for name in names if marker in name)
rows=[]
dirs = list(dict.fromkeys(shlex.split(field('bytestring','dynamic-library-dirs'))+shlex.split(field('bytestring','library-dirs'))))
byte_libraries = {p.resolve() for d in dirs for p in pathlib.Path(d).glob('libHSbytestring*.so')}
assert len(byte_libraries)==1,byte_libraries
byte_library = byte_libraries.pop(); symbol = exported(byte_library,'bytestring')
assert origin(symbol)==byte_library
rows.append({'kind':'compiler-boot-dependency','packageId':field('bytestring','id'),'symbol':symbol,'origin':str(byte_library)})
split_libraries = list((prefix/'cabal/store').rglob('libHSsplitmix*.so')); assert len(split_libraries)==1,split_libraries
split_library = split_libraries[0].resolve();symbol=exported(split_library,'splitmix')
assert origin(symbol)==split_library
rows.append({'kind':'native-compiled-dependency','symbol':symbol,'origin':str(split_library)})
rts = origin('hs_init')
rts_dirs = shlex.split(field('rts','dynamic-library-dirs'))+shlex.split(field('rts','library-dirs'))
assert any(rts.is_relative_to(pathlib.Path(d).resolve()) for d in rts_dirs)
assert rts.name.startswith('libHSrts')
rows.append({'kind':'compiler-RTS','packageId':field('rts','id'),'origin':str(rts),'supportsBoundThreads':bool(root.rtsSupportsBoundThreads())})
root.purifier_term()
print(json.dumps(rows))
