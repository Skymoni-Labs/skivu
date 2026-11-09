package com.skyjjgw.independent.ski;

import android.database.Cursor;
import android.database.MatrixCursor;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract.Document;
import android.provider.DocumentsContract.Root;
import android.provider.DocumentsProvider;
import java.io.*;

/** Real, separate-UID SAF provider for isolated emulator acceptance only. */
public class QaDocumentsProvider extends DocumentsProvider {
    private File base;
    private static final String[] ROOT_COLUMNS={Root.COLUMN_ROOT_ID,Root.COLUMN_DOCUMENT_ID,Root.COLUMN_TITLE,Root.COLUMN_FLAGS,Root.COLUMN_ICON,Root.COLUMN_MIME_TYPES};
    private static final String[] DOC_COLUMNS={Document.COLUMN_DOCUMENT_ID,Document.COLUMN_DISPLAY_NAME,Document.COLUMN_MIME_TYPE,Document.COLUMN_FLAGS,Document.COLUMN_SIZE,Document.COLUMN_LAST_MODIFIED};
    @Override public boolean onCreate(){
        base=new File(getContext().getFilesDir(),"saf-fixture");
        if(!base.isDirectory()&&!base.mkdirs())return false;
        File input=new File(base,"input-large.csv");
        if(!input.isFile())try(FileOutputStream out=new FileOutputStream(input)){
            BufferedOutputStream stream=new BufferedOutputStream(out,65536);
            byte[] line="original,中文😀,42\n".getBytes(java.nio.charset.StandardCharsets.UTF_8);
            for(int i=0;i<600000;i++)stream.write(line);
            stream.flush();
            out.getFD().sync();
        }catch(IOException e){return false;}
        return true;
    }
    private File file(String id)throws FileNotFoundException{
        try{
            File value=id.equals("root")?base:new File(base,id.substring("root/".length()));
            if(!id.equals("root")&&!id.startsWith("root/"))throw new IOException("Invalid document id");
            value=value.getCanonicalFile();String root=base.getCanonicalPath();
            if(!value.getPath().equals(root)&&!value.getPath().startsWith(root+File.separator))throw new IOException("Outside provider root");
            return value;
        }catch(IOException|RuntimeException e){throw new FileNotFoundException("Invalid fixture document");}
    }
    private String id(File value)throws FileNotFoundException{
        try{String path=value.getCanonicalPath(),root=base.getCanonicalPath();return path.equals(root)?"root":"root/"+path.substring(root.length()+1);}
        catch(IOException e){throw new FileNotFoundException();}
    }
    private String mime(File value){return value.isDirectory()?Document.MIME_TYPE_DIR:value.getName().endsWith(".csv")?"text/csv":value.getName().endsWith(".txt")?"text/plain":"application/octet-stream";}
    private void row(MatrixCursor cursor,File value)throws FileNotFoundException{
        if(!value.exists())throw new FileNotFoundException(value.getName());
        MatrixCursor.RowBuilder row=cursor.newRow();
        for(String column:cursor.getColumnNames())switch(column){
            case Document.COLUMN_DOCUMENT_ID:row.add(id(value));break;
            case Document.COLUMN_DISPLAY_NAME:row.add(value.equals(base)?"QA Skivu files":value.getName());break;
            case Document.COLUMN_MIME_TYPE:row.add(mime(value));break;
            case Document.COLUMN_FLAGS:row.add(value.isDirectory()?Document.FLAG_DIR_SUPPORTS_CREATE:Document.FLAG_SUPPORTS_WRITE);break;
            case Document.COLUMN_SIZE:row.add(value.isFile()?value.length():0);break;
            case Document.COLUMN_LAST_MODIFIED:row.add(value.lastModified());break;
            default:row.add(null);
        }
    }
    @Override public Cursor queryRoots(String[] projection){
        MatrixCursor cursor=new MatrixCursor(projection==null?ROOT_COLUMNS:projection);MatrixCursor.RowBuilder row=cursor.newRow();
        for(String column:cursor.getColumnNames())switch(column){
            case Root.COLUMN_ROOT_ID:row.add("qa");break;
            case Root.COLUMN_DOCUMENT_ID:row.add("root");break;
            case Root.COLUMN_TITLE:row.add("QA Skivu files");break;
            case Root.COLUMN_FLAGS:row.add(Root.FLAG_SUPPORTS_CREATE|Root.FLAG_LOCAL_ONLY|Root.FLAG_SUPPORTS_IS_CHILD);break;
            case Root.COLUMN_ICON:row.add(android.R.drawable.ic_menu_save);break;
            case Root.COLUMN_MIME_TYPES:row.add("*/*");break;
            default:row.add(null);
        }
        return cursor;
    }
    @Override public Cursor queryDocument(String documentId,String[] projection)throws FileNotFoundException{
        MatrixCursor cursor=new MatrixCursor(projection==null?DOC_COLUMNS:projection);row(cursor,file(documentId));return cursor;
    }
    @Override public Cursor queryChildDocuments(String parent,String[] projection,String sortOrder)throws FileNotFoundException{
        MatrixCursor cursor=new MatrixCursor(projection==null?DOC_COLUMNS:projection);File[] children=file(parent).listFiles();
        if(children!=null){java.util.Arrays.sort(children,java.util.Comparator.comparing(File::getName));for(File child:children)row(cursor,child);}
        return cursor;
    }
    @Override public String getDocumentType(String documentId)throws FileNotFoundException{return mime(file(documentId));}
    @Override public boolean isChildDocument(String parent,String child){try{return file(child).getPath().startsWith(file(parent).getPath()+File.separator);}catch(FileNotFoundException e){return false;}}
    @Override public ParcelFileDescriptor openDocument(String documentId,String mode,CancellationSignal signal)throws FileNotFoundException{
        return ParcelFileDescriptor.open(file(documentId),ParcelFileDescriptor.parseMode(mode));
    }
    @Override public String createDocument(String parent,String mime,String name)throws FileNotFoundException{
        if(name.isEmpty()||name.contains("/")||name.contains("\\")||name.equals(".")||name.equals(".."))throw new FileNotFoundException("Invalid name");
        File target=new File(file(parent),name);if(target.exists())throw new FileNotFoundException("File already exists");
        try{if(Document.MIME_TYPE_DIR.equals(mime)){if(!target.mkdir())throw new IOException();}else if(!target.createNewFile())throw new IOException();return id(target);}
        catch(IOException e){throw new FileNotFoundException("Cannot create document");}
    }
}
