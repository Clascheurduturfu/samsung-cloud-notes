package local.samsungcloudnotes

import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.io.File
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.launch

private val Orange = Color(0xFFFA471F)

@Composable
fun NotesTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val scheme = when {
        Build.VERSION.SDK_INT >= 31 -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme(primary = Orange)
        else -> lightColorScheme(primary = Orange)
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

@Composable
fun NotesApp(model: NotesViewModel, openFile: (File, String) -> Unit) {
    val wide = LocalConfiguration.current.screenWidthDp >= 840
    var confirmLogout by remember { mutableStateOf(false) }

    Surface(Modifier.fillMaxSize()) {
        if (wide) {
            Row(Modifier.fillMaxSize()) {
                Box(Modifier.width(380.dp).fillMaxHeight()) { Library(model, onLogout = { confirmLogout = true }) }
                VerticalDivider()
                Box(Modifier.weight(1f).fillMaxHeight()) {
                    if (model.selection != null) Editor(model, openFile, showBack = false) else Placeholder(model)
                }
            }
        } else {
            BackHandler(enabled = model.selection != null) { model.select(null) }
            if (model.selection != null) Editor(model, openFile, showBack = true) else Library(model, onLogout = { confirmLogout = true })
        }
    }

    model.error?.let { message ->
        AlertDialog(onDismissRequest = { model.error = null }, confirmButton = { TextButton(onClick = { model.error = null }) { Text("OK") } },
            title = { Text("Samsung Cloud Notes") }, text = { Text(message) })
    }
    if (confirmLogout) {
        AlertDialog(onDismissRequest = { confirmLogout = false },
            confirmButton = { TextButton(onClick = { confirmLogout = false; model.signOut() }) { Text("Log out") } },
            dismissButton = { TextButton(onClick = { confirmLogout = false }) { Text("Cancel") } },
            title = { Text("Log out of ${model.account}?") },
            text = { Text("The saved connection is removed. Cached notes and drafts stay on this device.") })
    }
}

@Composable
private fun Placeholder(model: NotesViewModel) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(if (model.account.isEmpty()) "Not signed in" else "Select a note", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun StatusLine(model: NotesViewModel, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        if (model.busy) { CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 2.dp); Spacer(Modifier.width(8.dp)) }
        Text(model.status, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Library(model: NotesViewModel, onLogout: () -> Unit) {
    val drawer = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    ModalNavigationDrawer(drawerState = drawer, drawerContent = {
        ModalDrawerSheet {
            Column(Modifier.verticalScroll(rememberScrollState()).padding(vertical = 12.dp)) {
                Text("Samsung Cloud Notes", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(horizontal = 28.dp, vertical = 12.dp))
                fun choose(id: String) { model.chooseFolder(id); scope.launch { drawer.close() } }
                NavigationDrawerItem(label = { Text("All notes") }, selected = model.folder == "all", onClick = { choose("all") }, modifier = Modifier.padding(horizontal = 12.dp))
                if (model.folders.isNotEmpty()) {
                    Text("Folders", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(horizontal = 28.dp, vertical = 8.dp))
                    model.folders.forEach { folder ->
                        NavigationDrawerItem(label = { Text(folder.name) }, selected = model.folder == folder.id, onClick = { choose(folder.id) }, modifier = Modifier.padding(horizontal = 12.dp))
                    }
                }
                NavigationDrawerItem(label = { Text("Trash") }, selected = model.folder == "trash", onClick = { choose("trash") }, modifier = Modifier.padding(horizontal = 12.dp))
                HorizontalDivider(Modifier.padding(vertical = 8.dp))
                if (model.account.isNotEmpty()) {
                    NavigationDrawerItem(label = { Text(model.account, maxLines = 1, overflow = TextOverflow.Ellipsis) }, badge = { Text("Log out") },
                        selected = false, onClick = { scope.launch { drawer.close() }; onLogout() }, modifier = Modifier.padding(horizontal = 12.dp))
                }
                Text("Version $appVersion · Unofficial client", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 28.dp, vertical = 12.dp))
            }
        }
    }) {
        Scaffold(topBar = {
            TopAppBar(title = { Text(model.folderTitle) },
                navigationIcon = { IconButton(onClick = { scope.launch { drawer.open() } }) { Icon(Icons.Default.Menu, "Folders") } },
                actions = { if (model.account.isNotEmpty()) IconButton(onClick = { model.requestRefresh() }, enabled = !model.busy) { Icon(Icons.Default.Refresh, "Refresh") } })
        }) { padding ->
            Column(Modifier.padding(padding).fillMaxSize()) {
                if (model.account.isEmpty() && model.notes.isEmpty()) { Welcome(model); return@Column }
                OutlinedTextField(value = model.search, onValueChange = { model.search = it }, placeholder = { Text("Search notes") },
                    leadingIcon = { Icon(Icons.Default.Search, null) }, singleLine = true,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp))
                StatusLine(model)
                PullToRefreshBox(isRefreshing = model.busy, onRefresh = { model.requestRefresh() }, modifier = Modifier.fillMaxSize()) {
                    val notes = model.visibleNotes
                    LazyColumn(Modifier.fillMaxSize()) {
                        items(notes, key = { it.id }) { note -> NoteRow(note, selected = note.id == model.selection) { model.select(note.id) } }
                        if (notes.isEmpty()) item { Text(if (model.busy) "Loading…" else "No notes", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.fillMaxWidth().padding(32.dp), textAlign = TextAlign.Center) }
                    }
                }
            }
        }
    }
}

@Composable
private fun NoteRow(note: NoteRecord, selected: Boolean, onClick: () -> Unit) {
    val locked = note.locked || note.encrypted
    ListItem(
        modifier = Modifier.clickable(enabled = !locked, onClick = onClick),
        headlineContent = { Text(if (note.locked) "Locked note" else note.title, fontWeight = FontWeight.Medium, maxLines = 2, overflow = TextOverflow.Ellipsis) },
        supportingContent = {
            Column {
                if (note.snippet.isNotEmpty()) Text(note.snippet, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date((note.modified).toLong())), style = MaterialTheme.typography.labelSmall)
            }
        },
        trailingContent = if (locked) ({ Icon(Icons.Default.Lock, "Locked") }) else null,
        tonalElevation = if (selected) 4.dp else 0.dp,
    )
}

@Composable
private fun Welcome(model: NotesViewModel) {
    Column(Modifier.fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Your Samsung notes, on any Android", style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
        Spacer(Modifier.height(12.dp))
        Text("Sign in with your Samsung account to access your notes directly from Samsung Cloud. Samsung Notes does not need to be installed.",
            color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = 420.dp))
        Spacer(Modifier.height(24.dp))
        Button(onClick = { model.signIn() }, enabled = !model.busy) { Text("Sign in with Samsung") }
        Spacer(Modifier.height(12.dp))
        StatusLine(model)
        Spacer(Modifier.height(24.dp))
        Text("Unofficial client · version $appVersion", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Editor(model: NotesViewModel, openFile: (File, String) -> Unit, showBack: Boolean) {
    val document = model.document
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    var showDrawing by remember(document?.serverID) {
        mutableStateOf(document != null && document.body.isBlank() && document.drawingPages.isNotEmpty())
    }
    val exporter = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/zip")) { uri ->
        if (uri != null) model.export { model.getApplication<android.app.Application>().contentResolver.openOutputStream(uri) }
    }
    Scaffold(topBar = {
        TopAppBar(
            title = { Text(if (model.dirty) "Local draft" else "Cloud copy", style = MaterialTheme.typography.titleSmall,
                color = if (model.dirty) Orange else MaterialTheme.colorScheme.onSurfaceVariant) },
            navigationIcon = { if (showBack) IconButton(onClick = { model.select(null) }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            actions = {
                TextButton(onClick = { model.save() }, enabled = !model.busy && model.dirty && model.editable) { Text("Save") }
                Box {
                    IconButton(onClick = { menu = true }, enabled = !model.busy && document != null) { Icon(Icons.Default.MoreVert, "More") }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(text = { Text("Reload cloud copy") }, onClick = { menu = false; model.reload() })
                        if (document?.drawingPages?.isNotEmpty() == true) DropdownMenuItem(text = { Text("Drawing PDF") }, onClick = {
                            menu = false; scope.launch { model.drawingFile()?.let { openFile(it, "application/pdf") } }
                        })
                        DropdownMenuItem(text = { Text("Export original…") }, onClick = { menu = false; exporter.launch(model.exportName) })
                    }
                }
            })
    }, bottomBar = { StatusLine(model, Modifier.navigationBarsPadding()) }) { padding ->
        if (document == null) {
            Box(Modifier.padding(padding).fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            return@Scaffold
        }
        val plain = TextFieldDefaults.colors(focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent,
            disabledContainerColor = Color.Transparent, focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent,
            disabledIndicatorColor = Color.Transparent)
        Column(Modifier.padding(padding).fillMaxSize().imePadding()) {
            TextField(value = model.title, onValueChange = { model.edit(newTitle = it) }, placeholder = { Text("Title") },
                enabled = model.editable && !model.busy, colors = plain, singleLine = true,
                textStyle = MaterialTheme.typography.titleLarge, modifier = Modifier.fillMaxWidth())
            HorizontalDivider()
            if (document.drawingPages.isNotEmpty()) {
                Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(selected = !showDrawing, onClick = { showDrawing = false }, label = { Text("Text") })
                    FilterChip(selected = showDrawing, onClick = { showDrawing = true }, label = { Text("Drawing") })
                }
            }
            Box(Modifier.weight(1f)) {
                if (showDrawing && document.drawingPages.isNotEmpty()) DrawingPreview(document.drawingPages)
                else TextField(value = model.body, onValueChange = { model.edit(newBody = it) },
                    enabled = model.editable && !model.busy && document.bodyObject != null, colors = plain, modifier = Modifier.fillMaxSize())
            }
            val attachments = document.assets.filter { !it.isInternal }
            if (attachments.isNotEmpty()) {
                HorizontalDivider()
                LazyRow(Modifier.padding(horizontal = 12.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(attachments, key = { it.id }) { asset ->
                        AssistChip(onClick = { scope.launch { model.attachmentFile(asset)?.let { (file, mime) -> openFile(file, mime) } } },
                            label = { Text(asset.fileName, maxLines = 1, overflow = TextOverflow.Ellipsis) })
                    }
                }
            }
            document.textIssue?.let { Text(it, style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) }
            if (model.draftConflict) Text("This local draft is based on an older cloud revision. Reload the note to archive the draft and open the current cloud copy.",
                style = MaterialTheme.typography.labelSmall, color = Orange, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
        }
    }
}

@Composable
private fun DrawingPreview(pages: List<DrawingPage>) {
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Text("Drawing preview · pen effects may differ", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        items(pages, key = { it.id }) { page ->
            Column {
                Text("Page ${page.id + 1}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Canvas(Modifier.fillMaxWidth().aspectRatio((page.width / page.height).toFloat()).border(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
                    page.drawScaled(drawContext.canvas.nativeCanvas, size.width)
                }
                if (page.unsupported > 0) Text("${page.unsupported} page objects cannot be previewed yet. Their original data is retained.", style = MaterialTheme.typography.labelSmall)
            }
        }
    }
}
